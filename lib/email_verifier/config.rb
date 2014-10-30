module EmailVerifier
  module Config
    class << self
      attr_accessor :verifier_email, :mailgun_public_api_key

      def reset
        @verifier_email = "nobody@nonexistant.com"
        @mailgun_public_api_key = nil
      end
    end
    self.reset
  end
end
