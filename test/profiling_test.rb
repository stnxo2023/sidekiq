require_relative "helper"

require "sidekiq/profiler"
require "sidekiq/api"
require "sidekiq/web"
require "rack/test"

describe "profiling" do
  before do
    @config = reset!

    # Ensure we don't touch external systems in our test suite
    Sidekiq::Web.configure do |c|
      c.middlewares.clear
      c.use Rack::Session::Cookie, secrets: "35c5108120cb479eecb4e947e423cad6da6f38327cf0ebb323e30816d74fa01f"
      c[:profile_view_url] = "https://localhost/public/%s"
      c[:profile_store_url] = "https://localhost/store"
    end
  end

  it "profiles" do
    ps = Sidekiq::ProfileSet.new
    assert_equal 0, ps.size

    skip("Not a usable Ruby") if RUBY_VERSION < "3.3"

    s = Sidekiq::Profiler.new(@config)
    assert_nil(s.call({}) {})
    result = s.call({"profile" => "mike", "class" => "SomeJob", "jid" => "1234"}) {
      sleep 0.001
      1
    }
    assert_kind_of Vernier::Result, result

    ps = Sidekiq::ProfileSet.new
    assert_equal 1, ps.size

    result = s.call({"profile" => "bob", "class" => "SomeJob", "jid" => "5678"}) {
      sleep 0.001
      1
    }
    assert_kind_of Vernier::Result, result
    ps = Sidekiq::ProfileSet.new
    assert_equal 2, ps.size

    profiles = ps.to_a
    assert_equal %w[bob-5678 mike-1234], profiles.map(&:key)
    assert_equal %w[5678 1234], profiles.map(&:jid)

    header = "\x1f\x8b".b
    profiles.each do |pr|
      assert pr.started_at
      assert_operator pr.size, :>, 2
      assert_operator pr.elapsed, :>, 0
      data = pr.data[0..1] # gzipped data
      assert_equal header, data # gzip magic number
    end

    Sidekiq.redis { |c| c.hset("mike-1234", "sid", "sid1234") }
    Sidekiq.redis { |c| c.hset("bob-5678", "sid", "sid5678") }

    get "/profiles"
    assert_match(/mike-1234/, last_response.body)
    assert_match(/bob-5678/, last_response.body)
    assert_match(/View/, last_response.body)

    get "/profiles/mike-1234"
    assert_equal 302, last_response.status
    assert_equal "https://localhost/public/sid1234", last_response.headers["Location"]

    get "/profiles/mike-1234/data"
    assert_equal "application/json", last_response.headers["Content-Type"]
    assert_equal "gzip", last_response.headers["Content-Encoding"]
    assert_equal header, last_response.body[0..1]

    # Verify we can turn off remote viewing by removing the store url
    Sidekiq::Web.configure do |config|
      config.tabs.delete "Profiles"
      config[:profile_store_url] = nil
    end

    get "/profiles"
    assert_match(/mike-1234/, last_response.body)
    assert_match(/bob-5678/, last_response.body)
    refute_match(/View/, last_response.body)

    get "/profiles/mike-1234"
    assert_equal 302, last_response.status
    assert_equal "/profiles", last_response.headers["Location"]
  end

  include Rack::Test::Methods

  def app
    @app ||= Rack::Lint.new(Sidekiq::Web.new)
  end
end
