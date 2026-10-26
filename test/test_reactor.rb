# frozen_string_literal: true

require_relative "helper"

require "puma/reactor"

class TestReactor < PumaTest

  parallelize_me!

  class FakeClient
    attr_reader :to_io, :wr, :name
    attr_accessor :timeout_at

    def initialize(name, timeout)
      @name = name
      @to_io, @wr = IO.pipe
      @timeout_at = Process.clock_gettime(Process::CLOCK_MONOTONIC) + timeout
    end

    def timeout
      [@timeout_at - Process.clock_gettime(Process::CLOCK_MONOTONIC), 0].max
    end

    def io_ok?
      !@to_io.closed?
    end

    def close
      @to_io.close unless @to_io.closed?
      @wr.close unless @wr.closed?
    end
  end

  def teardown
    @reactor&.shutdown
    @clients&.each(&:close)
  end

  def run_reactor(&block)
    @reactor = Puma::Reactor.new(:auto, &block)
    @reactor.run
    @reactor
  end

  # #add must return false only when the client was not accepted.  If the
  # adding thread is descheduled between pushing the client and waking the
  # selector while #shutdown runs to completion, the client is delivered by
  # the shutdown sweep and the wakeup raises IOError; add must still be true.
  def test_add_is_true_for_a_client_accepted_before_shutdown
    delivered = Queue.new
    reactor = run_reactor { |client| delivered << client; true }
    @clients = [client = FakeClient.new(:late, 10)]

    selector = reactor.instance_variable_get(:@selector)
    wakeup = selector.method(:wakeup)
    shut = false
    selector.define_singleton_method(:wakeup) do
      unless shut
        shut = true
        reactor.shutdown
      end
      wakeup.call
    end

    assert reactor.add(client)
    assert_equal client, Timeout.timeout(2) { delivered.pop }
    refute reactor.add(client)      # really shut down now
  end
end
