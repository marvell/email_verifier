require 'net/smtp'
require 'dnsruby'
require 'multimap'
require 'rest-client'
require 'json'

class EmailVerifier::Checker

  ##
  # Returns server object for given email address or throws exception
  # Object returned isn't yet connected. It has internally a list of
  # real mail servers got from MX dns lookup
  def initialize(address)
    @email = address

    @mailgun_public_api_key = EmailVerifier.config.mailgun_public_api_key
    if @mailgun_public_api_key && !valid?(@email)
      raise EmailVerifier::FailureException.new("#{address} is not valid")
    end

    @domain = address.split('@')[1]
    if EmailVerifier.config.domain_blacklist.include?(@domain)
      raise EmailVerifier::FailureException.new("#{@domain} is in blacklist")
    end

    @servers = list_mxs @domain
    raise EmailVerifier::NoMailServerException.new("No mail server for #{address}") if @servers.empty?
    @smtp = nil

    # this is because some mail servers won't give any info unless
    # a real user asks for it:
    @user_email = EmailVerifier.config.verifier_email
    _, @user_domain = @user_email.split "@"
  end

  def valid?(email)
    url_params = Multimap.new
    url_params[:address] = email
    url_params[:api_key] = @mailgun_public_api_key
    query_string = url_params.collect { |k, v| "#{k.to_s}=#{CGI::escape(v.to_s)}"}.join("&")
    url = "https://api.mailgun.net/v2/address/validate?#{query_string}"

    JSON.parse(RestClient.get(url))['is_valid']
  end

  def list_mxs(domain)
    return [] unless domain
    res = Dnsruby::DNS.new
    mxs = []
    res.each_resource(domain, 'MX') do |rr|
      mxs << { priority: rr.preference, address: rr.exchange.to_s }
    end
    mxs.sort_by { |mx| mx[:priority] }
  rescue Dnsruby::NXDomain
    raise EmailVerifier::NoMailServerException.new("#{domain} does not exist")
  end

  def is_connected
    !@smtp.nil?
  end

  def connect
    begin
      server = next_server
      raise EmailVerifier::OutOfMailServersException.new("Unable to connect to any one of mail servers for #{@email}") if server.nil?
      @smtp = Net::SMTP.start server[:address], 25, @user_domain
      return true
    rescue EmailVerifier::OutOfMailServersException => e
      raise EmailVerifier::OutOfMailServersException, e.message
    rescue => e
      retry
    end
  end

  def next_server
    @servers.shift
  end

  def verify
    self.mailfrom @user_email
    self.rcptto(@email)
  end

  def mailfrom(address)
    ensure_connected

    ensure_250 @smtp.mailfrom(address)
  end

  def rcptto(address)
    ensure_connected

    begin
      ensure_250 @smtp.rcptto(address)
    rescue => e
      if e.message[/^55/]
        return false
      else
        raise EmailVerifier::FailureException.new(e.message)
      end
    end
  end

  def ensure_connected
    raise EmailVerifier::NotConnectedException.new("You have to connect first") if @smtp.nil?
  end

  def ensure_250(smtp_return)
    if smtp_return.status.to_i == 250
      return true
    else
      raise EmailVerifier::FailureException.new "Mail server responded with #{smtp_return.status} when we were expecting 250"
    end
  end

end
