require 'pg'
require 'faraday'
require 'json'

class OauthDeviceTokenRequest
  attr_reader :openid_config_url
  attr_reader :scope
  attr_reader :client_id
  attr_reader :client_secret
  attr_reader :http
  attr_reader :token_endpoint
  attr_reader :polling_interval
  attr_reader :device_code

  def initialize(openid_config_url, scope, client_id, client_secret)
    @openid_config_url = openid_config_url
    @scope = scope
    @client_id = client_id
    @client_secret = client_secret

    # Initialize a base Faraday connection
    @http = Faraday.new do |f|
      f.request :url_encoded # Required for processing POST form data in OAuth2 endpoints
      # f.adapter Faraday.default_adapter
      # Type, Username, Password
      # f.request :authorization, :basic, client_id, client_secret
      f.response :json # Automatically parses JSON responses into a Hash accessible via response.body
    end
  end

  def request_auth_codes
    # =========================================================
    # Step 1: OpenID Discovery (Fetch metadata dynamically)
    # =========================================================
    puts "Step 1: Fetching OpenID Configuration..."
    discovery_res = http.get(openid_config_url)

    unless discovery_res.success?
      raise "Failed to fetch OpenID configuration: #{discovery_res.status}"
    end

    config = discovery_res.body
    device_auth_endpoint = config['device_authorization_endpoint']
    @token_endpoint       = config['token_endpoint']
    userinfo_endpoint    = config['userinfo_endpoint']
    received_issuer = config['issuer']

    unless device_auth_endpoint && token_endpoint
      raise "The identity provider metadata does not advertise required device or token endpoints."
    end

    # =========================================================
    # Step 2: Initiate Device Authorization Flow
    # =========================================================
    puts "\nStep 2: Requesting device authorization codes..."
    auth_res = http.post(device_auth_endpoint, scope:, client_id:, client_secret:)
    device_data = auth_res.body

    if device_data['error']
      puts "Initialization Error: #{device_data['error_description'] || device_data['error']}"
      exit
    end

    @polling_interval = device_data['interval'] || 5
    @device_code      = device_data['device_code']

    device_data
  end

  def print_user_info(device_data)
    user_code        = device_data['user_code']
    verification_uri = device_data['verification_uri']
    verification_uri_complete = device_data['verification_uri_complete']
    puts "--------------------------------------------------------"
    puts "Please navigate to: #{verification_uri}"
    puts "And enter the following code: #{user_code}"
    if verification_uri_complete
      puts
      puts "Or go to the following URL: #{verification_uri_complete}"
    end
    puts "--------------------------------------------------------"
  end

  def poll_token
    # =========================================================
    # Step 3: Poll Token Endpoint for Access Token
    # =========================================================
    puts "\nStep 3: Polling for user authorization..."
    token_data = nil

    loop do
      sleep(polling_interval)

      token_res = http.post(token_endpoint,
                            grant_type: 'urn:ietf:params:oauth:grant-type:device_code',
                            device_code: ,
                            client_id: , client_secret: )
      parsed_body = token_res.body

      if token_res.success?
        token_data = parsed_body
        puts "\n Success! Successfully authorized."
        break
      else
        error_code = parsed_body['error']

        case error_code
        when 'authorization_pending'
          print "." # User hasn't logged in yet, keep waiting
        when 'slow_down'
          polling_interval += 5
          puts "\nSlowing down polling interval to #{polling_interval} seconds..."
        when 'expired_token'
          puts "\nSession expired. Please restart the application to try again."
          exit
        else
          puts "\nUnrecoverable Error during token exchange: #{parsed_body['error_description'] || error_code}"
          exit
        end
      end
    end

    token_data['access_token']
  end

  def request
    device_data = request_auth_codes
    print_user_info(device_data)
    poll_token
  end
end

hook = proc do |conn, data|
  case data
  when PG::OAuthBearerRequest
    ci = conn.conninfo_hash
    req = OauthDeviceTokenRequest.new(data.openid_configuration, data.scope, ci[:oauth_client_id], ci[:oauth_client_secret])
    data.token = req.request
    true
  end
end

PG.connect(<<~EOT, set_auth_data_hook: hook) do |conn|
  host=localhost
  port=5432
  dbname=postgres
  user=postgres
  oauth_issuer=https://mock-oauth2:8080/realms/pg
  oauth_client_id=postgres
  oauth_client_secret=postgres
  oauth_scope=profile
EOT
  puts conn.exec("SELECT 'connected as user ' || user").getvalue(0,0)
end

exit


# Another option is to use the libpq-auth client provided by the PostgreSQL project:

require "pg"

hook = proc do |conn, data|
  case data
  when PG::PromptOAuthDevice
    p verification_uri: data.verification_uri,
      user_code: data.user_code,
      verification_uri_complete: data.verification_uri_complete,
      expires_in: data.expires_in
    true
  end
end

PG.connect(<<~EOT, set_auth_data_hook: hook) do |conn|
  host=localhost
  port=5432
  dbname=postgres
  user=postgres
  oauth_issuer=https://mock-oauth2:8080/realms/pg
  oauth_client_id=postgres
  oauth_client_secret=postgres
  oauth_scope=profile
EOT
  puts conn.exec("SELECT 'connected as user ' || user").getvalue(0,0)
end
