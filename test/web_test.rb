# frozen_string_literal: true

require_relative "helper"
require "sidekiq/web"
require "rack/test"
require "rack/session"

class WebJob
  include Sidekiq::Job

  def perform(a, b)
    a + b
  end
end

class LogDisplayer
  def add_pair(job)
    yield "External Logs", "<a href='https://example.com/logs/#{job.jid}'>Logs for #{job.jid}</a>"
  end
end

describe Sidekiq::Web do
  include Rack::Test::Methods

  def app
    @app ||= Rack::Lint.new(Sidekiq::Web.new)
  end

  def job_params(job, score)
    "#{score}-#{job["jid"]}"
  end

  before do
    @config = reset!

    Sidekiq::Web.configure do |c|
      c.middlewares.clear
      c.use Rack::Session::Cookie, secrets: "35c5108120cb479eecb4e947e423cad6da6f38327cf0ebb323e30816d74fa01f"
    end
  end

  it "passes on unexpected methods" do
    patch "/"
    assert_equal 404, last_response.status
    assert_equal "pass", last_response.headers["x-cascade"]
  end

  it "can show text with any locales" do
    rackenv = {"HTTP_ACCEPT_LANGUAGE" => "ru,en"}
    get "/", {}, rackenv
    assert_match(/Панель управления/, last_response.body)
    rackenv = {"HTTP_ACCEPT_LANGUAGE" => "es,en"}
    get "/", {}, rackenv
    assert_match(/Panel de Control/, last_response.body)
    rackenv = {"HTTP_ACCEPT_LANGUAGE" => "en-us"}
    get "/", {}, rackenv
    assert_match(/Dashboard/, last_response.body)
    rackenv = {"HTTP_ACCEPT_LANGUAGE" => "zh-CN"}
    get "/", {}, rackenv
    assert_match(/信息板/, last_response.body)
    rackenv = {"HTTP_ACCEPT_LANGUAGE" => "zh-TW"}
    get "/", {}, rackenv
    assert_match(/資訊主頁/, last_response.body)
    rackenv = {"HTTP_ACCEPT_LANGUAGE" => "nb"}
    get "/", {}, rackenv
    assert_match(/Oversikt/, last_response.body)
  end

  it "can provide a default, appropriate CSP for its content" do
    get "/", {}
    policies = last_response.headers["Content-Security-Policy"].split("; ")
    assert_includes(policies, "connect-src 'self' https: http: wss: ws:")
    assert_includes(policies, "style-src 'self' 'nonce-#{last_request.env[:csp_nonce]}'")
    assert_includes(policies, "script-src 'self' 'nonce-#{last_request.env[:csp_nonce]}'")
    assert_includes(policies, "object-src 'none'")
    assert_operator(last_request.env[:csp_nonce].length, :>=, 16)
  end

  it "provides a cheap HEAD response" do
    WebJob.perform_async
    assert_equal 1, Sidekiq::Queue.new.size

    head "/", {}
    assert_equal "", last_response.body.to_s
  end

  describe "busy" do
    it "can display workers" do
      @config.redis do |conn|
        conn.incr("busy")
        conn.sadd("processes", ["foo:1234"])
        conn.hset("foo:1234", "info", Sidekiq.dump_json("hostname" => "foo", "started_at" => Time.now.to_f, "queues" => [], "concurrency" => 10), "at", Time.now.to_f, "busy", 4)
        identity = "foo:1234:work"
        hash = {queue: "critical", payload: Sidekiq.dump_json({"class" => WebJob.name, "args" => [1, "abc"], "tags" => %w[foobar_100 <eviltag/>]}), run_at: Time.now.to_i}
        conn.hset(identity, 1001, Sidekiq.dump_json(hash))
      end
      assert_equal ["1001"], Sidekiq::WorkSet.new.map { |pid, tid, data| tid }

      get "/busy"
      assert_equal 200, last_response.status
      assert_match(/critical/, last_response.body)
      assert_match(/WebJob/, last_response.body)
      assert_match(/jobtag-foobar_100/, last_response.body)
      assert_match(/jobtag-&lt;eviltag\/&gt;/, last_response.body)
    end

    it "can quiet all processes" do
      identity = "identity"
      signals_key = "#{identity}-signals"
      @config.redis do |conn|
        conn.sadd("processes", [identity])
        conn.hset(identity, "info", Sidekiq.dump_json("hostname" => "foo", "identity" => identity), "at", Time.now.to_f, "busy", 0)
      end

      assert_nil @config.redis { |c| c.lpop signals_key }
      post "/busy", "quiet" => "Quiet All"
      assert_equal 302, last_response.status
      assert_equal "TSTP", @config.redis { |c| c.lpop signals_key }
    end

    it "can quiet a process" do
      identity = "identity"
      signals_key = "#{identity}-signals"
      @config.redis do |conn|
        conn.sadd("processes", [identity])
        conn.hset(identity, "info", Sidekiq.dump_json("hostname" => "foo", "identity" => identity), "at", Time.now.to_f, "busy", 0)
      end

      assert_nil @config.redis { |c| c.lpop signals_key }
      post "/busy", "quiet" => "1", "identity" => identity
      assert_equal 302, last_response.status
      assert_equal "TSTP", @config.redis { |c| c.lpop signals_key }
    end

    it "can stop a process" do
      identity = "identity"
      signals_key = "#{identity}-signals"
      @config.redis do |conn|
        conn.sadd("processes", [identity])
        conn.hset(identity, "info", Sidekiq.dump_json("hostname" => "foo", "identity" => identity), "at", Time.now.to_f, "busy", 0)
      end

      assert_nil @config.redis { |c| c.lpop signals_key }
      post "/busy", "stop" => "Stop All", "identity" => identity
      assert_equal 302, last_response.status
      assert_equal "TERM", @config.redis { |c| c.lpop signals_key }

      post "/busy", "stop" => "Stop All"
      assert_equal 302, last_response.status
      assert_equal "TERM", @config.redis { |c| c.lpop signals_key }
    end
  end

  it "can display queues" do
    Time.stub(:now, Time.now) do
      assert Sidekiq::Client.push("queue" => :foo, "class" => WebJob, "args" => [1, 3])

      get "/queues"
    end

    assert_equal 200, last_response.status
    assert_match(/foo/, last_response.body)
    refute_match(/HardJob/, last_response.body)
    assert_match(/0.0/, last_response.body)
    refute_match(/datetime/, last_response.body)
    Sidekiq::Queue.new("foo").clear

    ::Process.stub(:clock_gettime, ::Process.clock_gettime(::Process::CLOCK_REALTIME, :millisecond) - 65000) do
      assert Sidekiq::Client.push("queue" => :foo, "class" => WebJob, "args" => [1, 3], "enqueued_at" => (Time.now.to_f * 1000).floor)
    end

    get "/queues"
    assert_equal 200, last_response.status
    assert_match(/foo/, last_response.body)
    refute_match(/HardJob/, last_response.body)
    assert_match(/65.0/, last_response.body)
    assert_match(/datetime/, last_response.body)
  end

  it "handles queue view" do
    get "/queues/onmouseover=alert()"
    assert_equal 404, last_response.status

    get "/queues/foo_bar:123-wow."
    assert_equal 200, last_response.status
    assert_match(/foo_bar:123-wow\./, last_response.body)

    get "/queues/default"
    assert_equal 200, last_response.status
  end

  it "can sort on enqueued_at column" do
    @config.redis do |conn|
      (1000..1005).each do |i|
        conn.lpush("queue:default", Sidekiq.dump_json(args: [i], enqueued_at: Time.now.to_i + i))
      end
    end

    get "/queues/default?count=3" # direction is 'desc' by default
    assert_match(/\b1005\b/, last_response.body)
    refute_match(/\b1002\b/, last_response.body)

    get "/queues/default?count=3&direction=asc"
    assert_match(/\b1000\b/, last_response.body)
    refute_match(/\b1003\b/, last_response.body)
  end

  it "can delete a queue" do
    @config.redis do |conn|
      conn.rpush("queue:foo", "{\"args\":[],\"enqueued_at\":1567894960}")
      conn.sadd("queues", ["foo"])
    end

    get "/queues/foo"
    assert_equal 200, last_response.status

    post "/queues/foo"
    assert_equal 302, last_response.status

    @config.redis do |conn|
      refute_includes conn.smembers("queues"), "foo"
      refute(conn.exists("queue:foo") > 0)
    end
  end

  it "can attempt to pause a queue" do
    Sidekiq.stub(:pro?, true) do
      mock = Minitest::Mock.new
      mock.expect :pause!, true

      stub = lambda do |queue_name|
        assert_equal "foo", queue_name
        mock
      end

      Sidekiq::Queue.stub :new, stub do
        post "/queues/foo", "pause" => "pause"
        assert_equal 302, last_response.status
      end

      assert_mock mock
    end
  end

  it "can attempt to unpause a queue" do
    Sidekiq.stub(:pro?, true) do
      mock = Minitest::Mock.new
      mock.expect :unpause!, true

      stub = lambda do |queue_name|
        assert_equal "foo", queue_name
        mock
      end

      Sidekiq::Queue.stub :new, stub do
        post "/queues/foo", "unpause" => "unpause"
        assert_equal 302, last_response.status
      end

      assert_mock mock
    end
  end

  it "ignores to attempt to pause a queue with pro disabled" do
    mock = Minitest::Mock.new
    mock.expect :clear, true

    stub = lambda do |queue_name|
      assert_equal "foo", queue_name
      mock
    end

    Sidekiq::Queue.stub :new, stub do
      post "/queues/foo", "pause" => "pause"
      assert_equal 302, last_response.status
    end

    assert_mock mock
  end

  it "ignores to attempt to unpause a queue with pro disabled" do
    mock = Minitest::Mock.new
    mock.expect :clear, true

    stub = lambda do |queue_name|
      assert_equal "foo", queue_name
      mock
    end

    Sidekiq::Queue.stub :new, stub do
      post "/queues/foo", "unpause" => "unpause"
      assert_equal 302, last_response.status
    end

    assert_mock mock
  end

  it "can delete a job" do
    @config.redis do |conn|
      conn.rpush("queue:foo", '{"args":[],"enqueued_at":1567894960}')
      conn.rpush("queue:foo", '{"foo":"bar","args":[],"enqueued_at":1567894960}')
      conn.rpush("queue:foo", '{"foo2":"bar2","args":[],"enqueued_at":1567894960}')
    end

    get "/queues/foo"
    assert_equal 200, last_response.status

    post "/queues/foo/delete", key_val: "{\"foo\":\"bar\"}"
    assert_equal 302, last_response.status

    @config.redis do |conn|
      refute_includes conn.lrange("queue:foo", 0, -1), "{\"foo\":\"bar\"}"
    end
  end

  it "can display retries" do
    get "/retries"
    assert_equal 200, last_response.status
    assert_match(/found/, last_response.body)
    refute_match(/HardJob/, last_response.body)

    add_retry

    get "/retries"
    assert_equal 200, last_response.status
    refute_match(/found/, last_response.body)
    assert_match(/HardJob/, last_response.body)
  end

  it "displays custom job info" do
    Sidekiq::Web.configure do |c|
      c.custom_job_info_rows << LogDisplayer.new
    end
    params = add_retry
    get "/retries/#{job_params(*params)}"
    assert_equal 200, last_response.status
    assert_match(/https:\/\/example.com\/logs\//, last_response.body)
  ensure
    Sidekiq::Web.configure do |c|
      c.custom_job_info_rows.clear
    end
  end

  it "can display a single retry" do
    params = add_retry
    get "/retries/0-shouldntexist"
    assert_equal 302, last_response.status

    get "/retries/#{job_params(*params)}"
    assert_equal 200, last_response.status
    assert_match(/HardJob/, last_response.body)
  end

  it "handles missing retry" do
    get "/retries/0-shouldntexist"
    assert_equal 302, last_response.status
  end

  it "can filter retries" do
    3.times { add_retry }
    add_retry("MIKE1234")

    get "/retries", substr: "nope"
    refute_match(/RuntimeError/, last_response.body)

    get "/retries", substr: "nope"
    refute_match(/RuntimeError/, last_response.body)

    get "/retries", substr: "MIKE1234"
    assert_match(/MIKE1234/, last_response.body)
  end

  it "can delete multiple retries" do
    params = add_retry
    post "/retries", "key" => [job_params(*params)], "delete" => "Delete"
    assert_equal 302, last_response.status
    assert_equal "http://example.org/retries", last_response.headers["Location"]

    get "/retries"
    assert_equal 200, last_response.status
    refute_match(/#{params.first["args"][2]}/, last_response.body)
  end

  it "can delete a single retry" do
    params = add_retry
    post "/retries/#{job_params(*params)}", "delete" => "Delete"
    assert_equal 302, last_response.status
    assert_equal "http://example.org/retries", last_response.headers["Location"]

    get "/retries"
    assert_equal 200, last_response.status
    refute_match(/#{params.first["args"][2]}/, last_response.body)
  end

  it "can delete all retries" do
    3.times { add_retry }

    post "/retries/all/delete", "delete" => "Delete"
    assert_equal 0, Sidekiq::RetrySet.new.size
    assert_equal 302, last_response.status
    assert_equal "http://example.org/retries", last_response.headers["Location"]
  end

  it "can kill all retries" do
    3.times { add_retry }

    post "/retries/all/kill"
    assert_equal 0, Sidekiq::RetrySet.new.size
    assert_equal 3, Sidekiq::DeadSet.new.size
    assert_equal 302, last_response.status
    assert_equal "http://example.org/retries", last_response.headers["Location"]
  end

  it "can retry a single retry now" do
    params = add_retry
    post "/retries/#{job_params(*params)}", "retry" => "Retry"
    assert_equal 302, last_response.status
    assert_equal "http://example.org/retries", last_response.headers["Location"]

    get "/queues/default"
    assert_equal 200, last_response.status
    assert_match(/#{params.first["args"][2]}/, last_response.body)
  end

  it "can kill a single retry now" do
    params = add_retry
    post "/retries/#{job_params(*params)}", "kill" => "Kill"
    assert_equal 302, last_response.status
    assert_equal "http://example.org/retries", last_response.headers["Location"]

    get "/morgue"
    assert_equal 200, last_response.status
    assert_match(/#{params.first["args"][2]}/, last_response.body)
  end

  it "can display scheduled" do
    get "/scheduled"
    assert_equal 200, last_response.status
    assert_match(/found/, last_response.body)
    refute_match(/HardJob/, last_response.body)

    add_scheduled

    get "/scheduled"
    assert_equal 200, last_response.status
    refute_match(/found/, last_response.body)
    assert_match(/HardJob/, last_response.body)
  end

  it "can display a single scheduled job" do
    params = add_scheduled
    get "/scheduled/0-shouldntexist"
    assert_equal 302, last_response.status
    get "/scheduled/#{job_params(*params)}"
    assert_equal 200, last_response.status
    assert_match(/HardJob/, last_response.body)
  end

  it "can display a single scheduled job tags" do
    params = add_scheduled
    get "/scheduled/#{job_params(*params)}"
    assert_match(/tag1/, last_response.body)
    assert_match(/tag2/, last_response.body)
  end

  it "handles missing scheduled job" do
    get "/scheduled/0-shouldntexist"
    assert_equal 302, last_response.status
  end

  it "can filter scheduled" do
    3.times { add_scheduled }
    add_scheduled("MIKE1234")

    get "/scheduled", substr: "nope"
    refute_match(/RuntimeError/, last_response.body)

    get "/scheduled", substr: "nope"
    refute_match(/RuntimeError/, last_response.body)

    get "/scheduled", substr: "MIKE1234"
    assert_match(/MIKE1234/, last_response.body)
  end

  it "can add to queue a single scheduled job" do
    params = add_scheduled
    post "/scheduled/#{job_params(*params)}", "add_to_queue" => true
    assert_equal 302, last_response.status
    assert_equal "http://example.org/scheduled", last_response.headers["Location"]

    get "/queues/default"
    assert_equal 200, last_response.status
    assert_match(/#{params.first["args"][2]}/, last_response.body)
  end

  it "can delete a single scheduled job" do
    params = add_scheduled
    post "/scheduled/#{job_params(*params)}", "delete" => "Delete"
    assert_equal 302, last_response.status
    assert_equal "http://example.org/scheduled", last_response.headers["Location"]

    get "/scheduled"
    assert_equal 200, last_response.status
    refute_match(/#{params.first["args"][2]}/, last_response.body)
  end

  it "can delete scheduled" do
    params = add_scheduled
    @config.redis do |conn|
      assert_equal 1, conn.zcard("schedule")
      post "/scheduled", "key" => [job_params(*params)], "delete" => "Delete"
      assert_equal 302, last_response.status
      assert_equal "http://example.org/scheduled", last_response.headers["Location"]
      assert_equal 0, conn.zcard("schedule")
    end
  end

  it "can move scheduled to default queue" do
    q = Sidekiq::Queue.new
    params = add_scheduled
    @config.redis do |conn|
      assert_equal 1, conn.zcard("schedule")
      assert_equal 0, q.size
      post "/scheduled", "key" => [job_params(*params)], "add_to_queue" => "AddToQueue"
      assert_equal 302, last_response.status
      assert_equal "http://example.org/scheduled", last_response.headers["Location"]
      assert_equal 0, conn.zcard("schedule")
      assert_equal 1, q.size
      get "/queues/default"
      assert_equal 200, last_response.status
      assert_match(/#{params[0]["args"][2]}/, last_response.body)
    end
  end

  it "can retry all retries" do
    msg = add_retry.first
    add_retry

    post "/retries/all/retry", "retry" => "Retry"
    assert_equal 302, last_response.status
    assert_equal "http://example.org/retries", last_response.headers["Location"]
    assert_equal 2, Sidekiq::Queue.new("default").size

    get "/queues/default"
    assert_equal 200, last_response.status
    assert_match(/#{msg["args"][2]}/, last_response.body)
  end

  it "escape job args and error messages" do
    # on /retries page
    add_xss_retry
    get "/retries"
    assert_equal 200, last_response.status
    assert_match(/FailJob/, last_response.body)

    assert_includes last_response.body, "fail message: &lt;a&gt;hello&lt;/a&gt;"
    refute_includes last_response.body, "fail message: <a>hello</a>"

    assert_includes last_response.body, "args\">&quot;&lt;a&gt;hello&lt;/a&gt;&quot;<"
    refute_includes last_response.body, "args\"><a>hello</a><"

    # on /workers page
    @config.redis do |conn|
      pro = "foo:1234"
      conn.sadd("processes", [pro])
      conn.hset(pro, "info", Sidekiq.dump_json("started_at" => Time.now.to_f, "labels" => ["frumduz"], "queues" => [], "concurrency" => 10), "busy", 1, "beat", Time.now.to_f)
      identity = "#{pro}:work"
      hash = {queue: "critical", payload: Sidekiq.dump_json({"class" => "FailJob", "args" => ["<a>hello</a>"]}), run_at: Time.now.to_i}
      conn.hset(identity, 100001, Sidekiq.dump_json(hash))
      conn.incr("busy")
    end

    get "/busy"
    assert_equal 200, last_response.status
    assert_match(/FailJob/, last_response.body)
    assert_match(/frumduz/, last_response.body)
    assert_includes last_response.body, "&lt;a&gt;hello&lt;/a&gt;"
    refute_includes last_response.body, "<a>hello</a>"

    # on /queues page
    params = add_xss_retry # sorry, don't know how to easily make this show up on queues page otherwise.
    post "/retries/#{job_params(*params)}", "retry" => "Retry"
    assert_equal 302, last_response.status

    get "/queues/foo"
    assert_equal 200, last_response.status
    assert_includes last_response.body, "&lt;a&gt;hello&lt;/a&gt;"
    refute_includes last_response.body, "<a>hello</a>"
  end

  it "can show user defined tab" do
    Sidekiq::Web.tabs["Custom Tab"] = "/custom"

    get "/"
    assert_match "Custom Tab", last_response.body
  ensure
    Sidekiq::Web.tabs.delete "Custom Tab"
  end

  it "can display home" do
    get "/"
    assert_equal 200, last_response.status
  end

  it "can change the locale" do
    session_data = {"rack.session" => {}}
    headers = {"HTTP_REFERER" => "http://example.org/path", "HTTP_BASE_URL" => "http://example.org/"}

    post "/change_locale", {"locale" => "none"}, session_data.merge(headers)
    assert_nil last_request.env["rack.session"][:locale]
    assert_equal 302, last_response.status
    assert_equal "http://example.org/path", last_response.location

    post "/change_locale", {"locale" => "es"}, session_data.merge(headers)
    assert_equal "es", last_request.env["rack.session"][:locale]
    assert_equal 302, last_response.status
    assert_equal "http://example.org/path", last_response.location
  end

  describe "custom locales" do
    before do
      Sidekiq::Web.locales << File.join(File.dirname(__FILE__), "fixtures")
      Sidekiq::Web.tabs["Custom Tab"] = "/custom"
      Sidekiq::Web::Application.get("/custom") do
        clear_caches # ugly hack since I can't figure out how to access WebHelpers outside of this context
        t("translated_text")
      end
    end

    after do
      Sidekiq::Web.tabs.delete "Custom Tab"
      Sidekiq::Web.locales.pop
    end

    it "can show user defined tab with custom locales" do
      get "/custom"

      assert_match(/Changed text/, last_response.body)
    end
  end

  describe "dashboard/stats" do
    it "redirects to stats" do
      get "/dashboard/stats"
      assert_equal 302, last_response.status
      assert_equal "http://example.org/stats", last_response.headers["Location"]
    end
  end

  describe "stats" do
    before do
      @config.redis do |conn|
        conn.set("stat:processed", 5)
        conn.set("stat:failed", 2)
        conn.sadd("queues", ["default"])
      end
      2.times { add_retry }
      3.times { add_scheduled }
      4.times { add_worker }
    end

    it "works" do
      get "/stats"
      @response = Sidekiq.load_json(last_response.body)

      assert_equal 200, last_response.status
      assert_includes @response.keys, "sidekiq"
      assert_equal 5, @response["sidekiq"]["processed"]
      assert_equal 2, @response["sidekiq"]["failed"]
      assert_equal 4, @response["sidekiq"]["busy"]
      assert_equal 1, @response["sidekiq"]["processes"]
      assert_equal 2, @response["sidekiq"]["retries"]
      assert_equal 3, @response["sidekiq"]["scheduled"]
      assert_equal 0, @response["sidekiq"]["default_latency"]
      assert_includes @response.keys, "redis"
      assert_includes @response["redis"].keys, "redis_version"
      assert_includes @response["redis"].keys, "uptime_in_days"
      assert_includes @response["redis"].keys, "connected_clients"
      assert_includes @response["redis"].keys, "used_memory_human"
      assert_includes @response["redis"].keys, "used_memory_peak_human"
      assert_includes @response.keys, "server_utc_time"
    end
  end

  describe "bad JSON" do
    it "displays without error" do
      s = Sidekiq::DeadSet.new
      assert_equal 0, s.size
      (_, score) = kill_bad
      assert_equal 1, s.size

      get "/morgue"
      assert_equal 200, last_response.status
      assert_match(/#{score.to_i}/, last_response.body)
      assert_match("something bad", last_response.body)
      assert_equal 1, s.size

      post "/morgue/#{score}-", "delete" => "Delete"
      assert_equal 302, last_response.status
      assert_equal 1, s.size
    end
  end

  describe "stats/queues" do
    before do
      @config.redis do |conn|
        conn.set("stat:processed", 5)
        conn.set("stat:failed", 2)
        conn.sadd("queues", ["default", "queue2"])
      end
      2.times { add_retry }
      3.times { add_scheduled }
      4.times { add_worker }

      get "/stats/queues"
      @response = Sidekiq.load_json(last_response.body)
    end

    it "reports the queue depth" do
      assert_equal 0, @response["default"]
      assert_equal 0, @response["queue2"]
    end
  end

  describe "dead jobs" do
    it "shows empty index" do
      get "morgue"
      assert_equal 200, last_response.status
    end

    it "shows index with jobs" do
      (_, score) = add_dead
      get "morgue"
      assert_equal 200, last_response.status
      assert_match(/#{score}/, last_response.body)
    end

    it "can delete multiple dead" do
      params = add_dead
      post "/morgue", "key" => [job_params(*params)], "delete" => "Delete"
      assert_equal 302, last_response.status
      assert_equal "http://example.org/morgue", last_response.headers["Location"]

      get "/morgue"
      assert_equal 200, last_response.status
      refute_match(/#{params.first["args"][2]}/, last_response.body)
    end

    it "can delete all dead" do
      3.times { add_dead }

      assert_equal 3, Sidekiq::DeadSet.new.size
      post "/morgue/all/delete"
      assert_equal 0, Sidekiq::DeadSet.new.size
      assert_equal 302, last_response.status
      assert_equal "http://example.org/morgue", last_response.headers["Location"]
    end

    it "can filter dead" do
      3.times { add_dead }
      add_dead("MIKE1234")

      get "/morgue", substr: "nope"
      refute_match(/RuntimeError/, last_response.body)

      get "/morgue", substr: "nope"
      refute_match(/RuntimeError/, last_response.body)

      get "/morgue", substr: "MIKE1234"
      assert_match(/MIKE1234/, last_response.body)
    end

    it "can retry all dead" do
      3.times { add_dead }

      assert_equal 0, Sidekiq::Queue.new("foo").size
      assert_equal 3, Sidekiq::DeadSet.new.size
      post "/morgue/all/retry"
      assert_equal 0, Sidekiq::DeadSet.new.size
      assert_equal 3, Sidekiq::Queue.new("foo").size
      assert_equal 302, last_response.status
      assert_equal "http://example.org/morgue", last_response.headers["Location"]
    end

    it "can display a dead job" do
      params = add_dead
      get "/morgue/#{job_params(*params)}"
      assert_equal 200, last_response.status
    end

    it "can retry a dead job" do
      params = add_dead
      post "/morgue/#{job_params(*params)}", "retry" => "Retry"
      assert_equal 302, last_response.status
      assert_equal "http://example.org/morgue", last_response.headers["Location"]
      assert_equal 0, Sidekiq::DeadSet.new.size

      params = add_dead("jid-with-hyphen")
      post "/morgue/#{job_params(*params)}", "retry" => "Retry"
      assert_equal 302, last_response.status
      assert_equal 0, Sidekiq::DeadSet.new.size

      get "/queues/foo"
      assert_equal 200, last_response.status
      assert_match(/#{params.first["args"][2]}/, last_response.body)
    end
  end

  def add_scheduled(jid = SecureRandom.hex(12))
    score = Time.now.to_f
    msg = {"class" => "HardJob",
           "args" => ["bob", 1, Time.now.to_f],
           "jid" => jid,
           "tags" => ["tag1", "tag2"]}
    @config.redis do |conn|
      conn.zadd("schedule", score, Sidekiq.dump_json(msg))
    end
    [msg, score]
  end

  def add_retry(jid = SecureRandom.hex(12))
    msg = {"class" => "HardJob",
           "args" => ["bob", 1, Time.now.to_f],
           "queue" => "default",
           "error_message" => "Some fake message",
           "error_class" => "RuntimeError",
           "retry_count" => 0,
           "failed_at" => Time.now.to_f,
           "jid" => jid}
    score = Time.now.to_f
    @config.redis do |conn|
      conn.zadd("retry", score, Sidekiq.dump_json(msg))
    end

    [msg, score]
  end

  def add_dead(jid = SecureRandom.hex(12))
    msg = {"class" => "HardJob",
           "args" => ["bob", 1, Time.now.to_f],
           "queue" => "foo",
           "error_message" => "Some fake message",
           "error_class" => "RuntimeError",
           "retry_count" => 0,
           "failed_at" => Time.now.to_f,
           "jid" => jid}
    score = Time.now.to_f
    @config.redis do |conn|
      conn.zadd("dead", score, Sidekiq.dump_json(msg))
    end
    [msg, score]
  end

  def kill_bad
    job = "{ something bad }"
    score = Time.now.to_f
    @config.redis do |conn|
      conn.zadd("dead", score, job)
    end
    [job, score]
  end

  def add_xss_retry(job_id = SecureRandom.hex(12))
    msg = {"class" => "FailJob",
           "args" => ["<a>hello</a>"],
           "queue" => "foo",
           "error_message" => "fail message: <a>hello</a>",
           "error_class" => "RuntimeError",
           "retry_count" => 0,
           "failed_at" => Time.now.to_i * 1000,
           "jid" => SecureRandom.hex(12)}
    score = Time.now.to_f
    @config.redis do |conn|
      conn.zadd("retry", score, Sidekiq.dump_json(msg))
    end

    [msg, score]
  end

  def hostname
    ENV["DYNO"] || Socket.gethostname
  end

  def add_worker
    key = "#{hostname}:#{$$}"
    msg = "{\"queue\":\"default\",\"payload\":{\"retry\":true,\"queue\":\"default\",\"timeout\":20,\"backtrace\":5,\"class\":\"HardJob\",\"args\":[\"bob\",10,5],\"jid\":\"2b5ad2b016f5e063a1c62872\"},\"run_at\":1361208995}"
    @config.redis do |conn|
      conn.multi do |transaction|
        transaction.sadd("processes", [key])
        transaction.hset(key, "info", Sidekiq.dump_json("hostname" => "foo", "started_at" => Time.now.to_f, "queues" => []), "at", Time.now.to_f, "busy", 4)
        transaction.hset("#{key}:work", Time.now.to_f, msg)
      end
    end
  end

  describe "basic auth" do
    include Rack::Test::Methods

    before do
      Sidekiq::Web.use(Rack::Auth::Basic) { |user, pass| user == "a" && pass == "b" }
      Sidekiq::Web.use(Rack::Session::Cookie, secret: SecureRandom.hex(32))
    end

    it "requires basic authentication" do
      get "/"

      assert_equal 401, last_response.status
      refute_nil last_response.headers["WWW-Authenticate"]
    end

    it "authenticates successfully" do
      basic_authorize "a", "b"

      get "/"
      assert_equal 200, last_response.status
      get "/?days=1000000"
      assert_equal 401, last_response.status
    end
  end

  describe "Metrics" do
    before do
      require "sidekiq/component"
      require "sidekiq/metrics/tracking"
      t = Sidekiq::Metrics::ExecutionTracker.new(@config)
      t.track("default", "MikeJob") do
        sleep 0.02
      end
      t.flush
    end

    describe "/metrics" do
      it "calls the Sidekiq::Metrics::Query and renders correctly" do
        get "/metrics", {period: "4h"}.compact
        assert_equal 200, last_response.status
        assert_match(/Metrics/, last_response.body)
      end

      it "supports filtering" do
        get "/metrics", "substr" => "mike"
        assert_equal 200, last_response.status
        assert_match(/MikeJob/, last_response.body)

        get "/metrics", "substr" => "notfound"
        assert_equal 200, last_response.status
        refute_match(/MikeJob/, last_response.body)
      end
    end

    describe "/metrics/:job" do
      it "calls the Sidekiq::Metrics::Query and renders correctly" do
        job_result_mock = Minitest::Mock.new
        job_result_mock.expect(:totals, {"s" => 1})
        3.times { job_result_mock.expect(:hist, {"FooJob" => []}) }

        result_mock = Minitest::Mock.new
        result_mock.expect(:job_results, {"FooJob" => job_result_mock})
        result_mock.expect(:starts_at, Time.now - 3600)
        result_mock.expect(:starts_at, Time.now - 3600)
        result_mock.expect(:ends_at, Time.now)
        result_mock.expect(:ends_at, Time.now)
        result_mock.expect(:marks, [])

        query_mock = Minitest::Mock.new
        query_mock.expect :for_job, result_mock do |job, minutes:|
          assert_equal "FooJob", job
          assert_equal minutes, 120
        end

        Sidekiq::Metrics::Query.stub :new, query_mock do
          get "/metrics/FooJob", {period: "2h"}
          assert_equal 200, last_response.status
          assert_match(/Metrics/, last_response.body)
          assert_match(/FooJob/, last_response.body)
          assert_match(/8h/, last_response.body)
          refute_match(/24h/, last_response.body)
        end
      end
    end
  end
end
