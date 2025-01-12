# frozen_string_literal: true

require 'rails_helper'

describe ApplicationRequest do
  before do
    ApplicationRequest.enable
    ApplicationRequest.last_flush = Time.now.utc
  end

  after do
    ApplicationRequest.disable
    ApplicationRequest.clear_cache!
  end

  def inc(key, opts = nil)
    ApplicationRequest.increment!(key, opts)
  end

  def disable_date_flush!
    freeze_time(Time.now)
    ApplicationRequest.last_flush = Time.now.utc
  end

  context "readonly test" do
    it 'works even if redis is in readonly' do
      disable_date_flush!

      inc(:http_total)
      inc(:http_total)

      Discourse.redis.without_namespace.stubs(:eval).raises(Redis::CommandError.new("READONLY"))
      Discourse.redis.without_namespace.stubs(:evalsha).raises(Redis::CommandError.new("READONLY"))
      Discourse.redis.without_namespace.stubs(:set).raises(Redis::CommandError.new("READONLY"))

      # flush will be deferred no error raised
      inc(:http_total, autoflush: 3)
      ApplicationRequest.write_cache!

      Discourse.redis.without_namespace.unstub(:eval)
      Discourse.redis.without_namespace.unstub(:evalsha)
      Discourse.redis.without_namespace.unstub(:set)

      inc(:http_total, autoflush: 3)
      expect(ApplicationRequest.http_total.first.count).to eq(3)
    end
  end

  it 'logs nothing for an unflushed increment' do
    ApplicationRequest.increment!(:page_view_anon)
    expect(ApplicationRequest.count).to eq(0)
  end

  it 'can automatically flush' do
    disable_date_flush!

    inc(:http_total)
    inc(:http_total)
    inc(:http_total, autoflush: 3)

    expect(ApplicationRequest.http_total.first.count).to eq(3)

    inc(:http_total)
    inc(:http_total)
    inc(:http_total, autoflush: 3)

    expect(ApplicationRequest.http_total.first.count).to eq(6)
  end

  it 'can flush based on time' do
    t1 = Time.now.utc.at_midnight
    freeze_time(t1)
    ApplicationRequest.write_cache!
    inc(:http_total)
    expect(ApplicationRequest.count).to eq(0)

    freeze_time(t1 + ApplicationRequest.autoflush_seconds + 1)
    inc(:http_total)

    expect(ApplicationRequest.count).to eq(1)
  end

  it 'flushes yesterdays results' do
    t1 = Time.now.utc.at_midnight
    freeze_time(t1)
    inc(:http_total)
    freeze_time(t1.tomorrow)
    inc(:http_total)

    ApplicationRequest.write_cache!
    expect(ApplicationRequest.count).to eq(2)
  end

  it 'clears cache correctly' do
    # otherwise we have test pollution
    inc(:page_view_anon)
    ApplicationRequest.clear_cache!
    ApplicationRequest.write_cache!

    expect(ApplicationRequest.count).to eq(0)
  end

  it 'logs a few counts once flushed' do
    time = Time.now.at_midnight
    freeze_time(time)

    3.times { inc(:http_total) }
    2.times { inc(:http_2xx) }
    4.times { inc(:http_3xx) }

    ApplicationRequest.write_cache!

    expect(ApplicationRequest.http_total.first.count).to eq(3)
    expect(ApplicationRequest.http_2xx.first.count).to eq(2)
    expect(ApplicationRequest.http_3xx.first.count).to eq(4)

  end
end
