module Madmin
  class MagicLinksController < Madmin::ResourceController
    def revoke
      @record.destroy!
      redirect_to resource.index_path, notice: "Magic link revoked."
    end
  end
end
