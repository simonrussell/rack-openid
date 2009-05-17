require 'rubygems'
gem 'rack', '>= 0.4'
gem 'ruby-openid', '>=2.1.6'

require 'test/unit'
require 'mocha'
require 'net/http'

require 'rack/mock'
require 'rack/session/pool'
require 'rack/openid'

class HeaderTest < Test::Unit::TestCase
  def test_build_header
    assert_equal 'OpenID identity="http://example.com/"',
      Rack::OpenID.build_header(:identity => "http://example.com/")
    assert_equal 'OpenID identity="http://example.com/?foo=bar"',
      Rack::OpenID.build_header(:identity => "http://example.com/?foo=bar")
    assert_equal 'OpenID identity="http://example.com/", return_to="http://example.org/"',
      Rack::OpenID.build_header(:identity => "http://example.com/", :return_to => "http://example.org/")
    assert_equal 'OpenID identity="http://example.com/", required="nickname,email"',
      Rack::OpenID.build_header(:identity => "http://example.com/", :required => ["nickname", "email"])
  end

  def test_parse_header
    assert_equal({"identity" => "http://example.com/"},
      Rack::OpenID.parse_header('OpenID identity="http://example.com/"'))
    assert_equal({"identity" => "http://example.com/?foo=bar"},
      Rack::OpenID.parse_header('OpenID identity="http://example.com/?foo=bar"'))
    assert_equal({"identity" => "http://example.com/", "return_to" => "http://example.org/"},
      Rack::OpenID.parse_header('OpenID identity="http://example.com/", return_to="http://example.org/"'))
    assert_equal({"identity" => "http://example.com/", "required" => ["nickname", "email"]},
      Rack::OpenID.parse_header('OpenID identity="http://example.com/", required="nickname,email"'))
  end
end

class OpenIDTest < Test::Unit::TestCase
  RotsServer = 'http://localhost:9292'
  PidFile = File.expand_path('tmp/rack.pid')

  def setup
    unless File.exist?(PidFile)
      system("rackup -D -P #{PidFile} test/openid_server.ru")
      sleep 0.5
    end
    @pid = File.read(PidFile)

    assert_nothing_raised(Errno::ECONNREFUSED) {
      uri = URI.parse(RotsServer)
      response = Net::HTTP.get_response(uri)
    }
  end

  def teardown
    system("kill #{@pid}")
    sleep 0.1
  end

  def test_with_get
    @app = app
    process('/', :method => 'GET')
    follow_redirect!
    assert_equal 200, @response.status
    assert_equal 'GET', @response.headers['X-Method']
    assert_equal '/', @response.headers['X-Path']
    assert_equal 'success', @response.body
  end

  def test_with_post_method
    @app = app
    process('/', :method => 'POST')
    follow_redirect!
    assert_equal 200, @response.status
    assert_equal 'POST', @response.headers['X-Method']
    assert_equal '/', @response.headers['X-Path']
    assert_equal 'success', @response.body
  end

  def test_with_custom_return_to
    @app = app(:return_to => 'http://example.org/complete')
    process('/', :method => 'GET')
    follow_redirect!
    assert_equal 200, @response.status
    assert_equal 'GET', @response.headers['X-Method']
    assert_equal '/complete', @response.headers['X-Path']
    assert_equal 'success', @response.body
  end

  def test_with_post_method_custom_return_to
    @app = app(:return_to => 'http://example.org/complete')
    process('/', :method => 'POST')
    follow_redirect!
    assert_equal 200, @response.status
    assert_equal 'GET', @response.headers['X-Method']
    assert_equal '/complete', @response.headers['X-Path']
    assert_equal 'success', @response.body
  end

  def test_with_custom_return_method
    @app = app(:method => 'put')
    process('/', :method => 'GET')
    follow_redirect!
    assert_equal 200, @response.status
    assert_equal 'PUT', @response.headers['X-Method']
    assert_equal '/', @response.headers['X-Path']
    assert_equal 'success', @response.body
  end

  def test_with_simple_registration_fields
    @app = app(:required => ['nickname', 'email'], :optional => 'fullname')
    process('/', :method => 'GET')
    follow_redirect!
    assert_equal 200, @response.status
    assert_equal 'GET', @response.headers['X-Method']
    assert_equal '/', @response.headers['X-Path']
    assert_equal 'success', @response.body
  end

  def test_with_attribute_exchange
    @app = app(
      :required => ['http://axschema.org/namePerson/friendly', 'http://axschema.org/contact/email'],
      :optional => 'http://axschema.org/namePerson')
    process('/', :method => 'GET')
    follow_redirect!
    assert_equal 200, @response.status
    assert_equal 'GET', @response.headers['X-Method']
    assert_equal '/', @response.headers['X-Path']
    assert_equal 'success', @response.body
  end

  def test_with_missing_id
    @app = app(:identifier => "#{RotsServer}/john.doe")
    process('/', :method => 'GET')
    follow_redirect!
    assert_equal 400, @response.status
    assert_equal 'GET', @response.headers['X-Method']
    assert_equal '/', @response.headers['X-Path']
    assert_equal 'cancel', @response.body
  end

  def test_with_timeout
    @app = app(:identifier => RotsServer)
    process('/', :method => "GET")
    assert_equal 400, @response.status
    assert_equal 'GET', @response.headers['X-Method']
    assert_equal '/', @response.headers['X-Path']
    assert_equal 'missing', @response.body
  end

  private
    def app(options = {})
      options[:identifier] ||= "#{RotsServer}/john.doe?openid.success=true"

      app = lambda { |env|
        if resp = env[Rack::OpenID::RESPONSE]
          headers = {'X-Path' => env['PATH_INFO'], 'X-Method' => env['REQUEST_METHOD']}
          if resp.status == :success
            [200, headers, [resp.status.to_s]]
          else
            [400, headers, [resp.status.to_s]]
          end
        else
          [401, {Rack::OpenID::AUTHENTICATE_HEADER => Rack::OpenID.build_header(options)}, []]
        end
      }
      Rack::Session::Pool.new(Rack::OpenID.new(app))
    end

    def process(*args)
      env = Rack::MockRequest.env_for(*args)
      @response = Rack::MockResponse.new(*@app.call(env))
    end

    def follow_redirect!
      assert @response
      assert_equal 303, @response.status
      location = URI.parse(@response.headers['Location'])
      response = Net::HTTP.get_response(location)
      uri = URI(response['Location'])
      process("#{uri.path}?#{uri.query}")
    end
end
