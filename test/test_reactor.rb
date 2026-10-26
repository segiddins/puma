# frozen_string_literal: true

require_relative "helper"

require "puma/reactor"

class TestReactor < PumaTest

  parallelize_me!

  class FakeClient
    attr_reader :to_io, :wr, :name
    attr_accessor :timeout_at

    def initialize(name, timeout, broken: false)
      @name = name
      @to_io, @wr = IO.pipe
      @timeout_at = Process.clock_gettime(Process::CLOCK_MONOTONIC) + timeout
      @broken = broken
    end

    # Any exception raised while the reactor registers a client (here: from
    # #to_io; a closed io raising IOError inside NIO is the realistic case).
    def to_io
      raise "broken client" if @broken
      @to_io
    end

    def timeout
      [@timeout_at - Process.clock_gettime(Process::CLOCK_MONOTONIC), 0].max
    end

    def io_ok?
      true
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

  # A client whose timeout is reset while it stays in the reactor (the
  # Server#reactor_wakeup partial-request path) must not delay the timeouts
  # of clients sorted behind it.
  def test_timeout_reset_of_a_kept_client_does_not_delay_other_timeouts
    delivered = Queue.new
    @clients = [
      slow = FakeClient.new(:slow, 0.05),
      victim = FakeClient.new(:victim, 0.2),
    ]
    reactor = run_reactor do |client|
      delivered << client.name
      if client.equal?(slow)
        client.to_io.read_nonblock(16, exception: false)
        client.timeout_at = Process.clock_gettime(Process::CLOCK_MONOTONIC) + 5
        false        # partial request: stay registered with a new timeout
      else
        true
      end
    end
    reactor.add slow
    reactor.add victim
    sleep 0.02
    slow.wr.write "partial"

    assert_equal :slow, Timeout.timeout(2) { delivered.pop }
    assert_equal :victim, Timeout.timeout(2) { delivered.pop }
  end

  # A client that raises on registration must not leave the clients
  # registered before it in the same drain out of order (their timeouts would
  # otherwise only be checked after the next #add).
  def test_registration_error_does_not_delay_other_timeouts
    delivered = Queue.new
    @clients = [
      far = FakeClient.new(:far, 10),
      near = FakeClient.new(:near, 0.1),
      broken = FakeClient.new(:broken, 10, broken: true),
    ]
    reactor = run_reactor do |client|
      delivered << client.name
      true
    end
    reactor.add far
    reactor.add near
    reactor.add broken

    assert_equal :near, Timeout.timeout(2) { delivered.pop }
  end

  # The clients queued behind the failing one must be registered promptly too:
  # the interrupted drain has already consumed their wakeup, so the loop must
  # not block in select while @input is non-empty.
  def test_registration_error_does_not_strand_queued_clients
    delivered = Queue.new
    @clients = [
      broken = FakeClient.new(:broken, 10, broken: true),
      near = FakeClient.new(:near, 0.1),
    ]
    reactor = run_reactor do |client|
      delivered << client.name
      true
    end
    reactor.add broken
    reactor.add near

    assert_equal :near, Timeout.timeout(2) { delivered.pop }
  end
end
