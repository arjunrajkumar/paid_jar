require "test_helper"

class EmailConnection::Gmail::OauthClientTest < ActiveSupport::TestCase
  setup do
    @config = FakeConfiguration.new
    @client = EmailConnection::Gmail::OauthClient.new(config: @config)
  end

  test "authorization requests offline consent with the required Gmail scopes" do
    uri = URI(@client.authorization_url(
      state: "signed-state",
      redirect_uri: "https://example.com/gmail/callback"
    ))
    params = Rack::Utils.parse_query(uri.query)

    assert_equal "offline", params["access_type"]
    assert_equal "consent", params["prompt"]
    assert_equal "signed-state", params["state"]
    assert_equal "true", params["include_granted_scopes"]
    assert_equal @config.scopes.sort, params.fetch("scope").split.sort
    assert_includes params.fetch("scope").split, EmailConnection::Gmailable::EMAIL_SCOPE
    assert_includes params.fetch("scope").split, EmailConnection::Gmailable::PROFILE_SCOPE
    assert_includes params.fetch("scope").split, EmailConnection::Gmailable::SEND_SCOPE
    assert_includes params.fetch("scope").split, EmailConnection::Gmailable::READ_SCOPE
    refute_includes params.fetch("scope").split, "email"
    refute_includes params.fetch("scope").split, "profile"
    refute_includes params.fetch("scope").split, "https://www.googleapis.com/auth/gmail.modify"
  end

  test "refreshes tokens without a real Google request" do
    stub_request(:post, @config.token_uri.to_s)
      .with(body: hash_including(
        "grant_type" => "refresh_token",
        "refresh_token" => "refresh-token"
      ))
      .to_return(
        status: 200,
        body: { access_token: "new-token", expires_in: 3600 }.to_json,
        headers: { "Content-Type" => "application/json" }
      )

    token_data = @client.refresh_token(refresh_token: "refresh-token")

    assert_equal "new-token", token_data.fetch("access_token")
  end

  test "sets bounded connection and response timeouts" do
    response = Net::HTTPOK.new("1.1", "200", "OK")
    response.stubs(:body).returns({ access_token: "new-token" }.to_json)
    http = mock
    http.expects(:request).with(instance_of(Net::HTTP::Post)).returns(response)
    Net::HTTP.expects(:start).with(
      @config.token_uri.hostname,
      @config.token_uri.port,
      use_ssl: true,
      open_timeout: 5,
      read_timeout: 10
    ).yields(http).returns(response)

    token_data = @client.refresh_token(refresh_token: "refresh-token")

    assert_equal "new-token", token_data.fetch("access_token")
  end

  test "classifies a revoked refresh token as an authentication error" do
    stub_request(:post, @config.token_uri.to_s).to_return(
      status: 400,
      body: { error: "invalid_grant" }.to_json,
      headers: { "Content-Type" => "application/json" }
    )

    assert_raises EmailConnection::Errors::AuthenticationError do
      @client.refresh_token(refresh_token: "revoked-token")
    end
  end

  test "classifies a non-JSON provider outage as temporary before parsing the body" do
    stub_request(:post, @config.token_uri.to_s).to_return(
      status: 503,
      body: "upstream proxy unavailable",
      headers: { "Content-Type" => "text/html" }
    )

    assert_raises EmailConnection::Errors::TemporaryDeliveryError do
      @client.refresh_token(refresh_token: "refresh-token")
    end
  end

  test "classifies an HTTP request timeout response as temporary" do
    stub_request(:post, @config.token_uri.to_s).to_return(
      status: 408,
      body: "request timed out",
      headers: { "Content-Type" => "text/plain" }
    )

    error = assert_raises EmailConnection::Errors::TemporaryDeliveryError do
      @client.refresh_token(refresh_token: "refresh-token")
    end

    assert_equal "Google is temporarily unavailable.", error.message
    assert_nil error.cause
  end

  test "does not retain private network error details as a cause" do
    Net::HTTP.stubs(:start).raises(SocketError, "private resolver details")

    error = assert_raises EmailConnection::Errors::TemporaryDeliveryError do
      @client.refresh_token(refresh_token: "refresh-token")
    end

    assert_equal "Google is temporarily unavailable.", error.message
    assert_nil error.cause
    assert_not_includes error.full_message, "private resolver details"
  end

  class FakeConfiguration
    def client_id = "google-client-id"
    def client_secret = "google-client-secret"
    def scopes = EmailConnection::Gmail::Configuration::SCOPES
    def authorization_uri = URI("https://accounts.google.test/authorize")
    def token_uri = URI("https://oauth2.google.test/token")
    def userinfo_uri = URI("https://google.test/userinfo")
  end
end
