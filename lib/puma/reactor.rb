# frozen_string_literal: true

module Puma
  class UnsupportedBackend < StandardError; end

  # Monitors a collection of IO objects, calling a block whenever
  # any monitored object either receives data or times out, or when the Reactor shuts down.
  #
  # The waiting/wake up is performed with nio4r, which will use the appropriate backend (libev,
  # Java NIO or just plain IO#select). The call to `NIO::Selector#select` will
  # 'wakeup' any IO object that receives data.
  #
  # This class additionally tracks a timeout for every added object,
  # and wakes up any object when its timeout elapses.
  #
  # The implementation uses a Queue to synchronize adding new objects from the internal select loop.
  class Reactor

    # @!attribute [rw] reactor_max
    #   Maximum number of clients in the selector.  Reset with calls to `Server.stats`.
    attr_accessor :reactor_max
    attr_reader :reactor_size

    # Create a new Reactor to monitor IO objects added by #add.
    # The provided block will be invoked when an IO has data available to read,
    # its timeout elapses, or when the Reactor shuts down.
    def initialize(backend, &block)
      require 'nio'
      valid_backends = [:auto, *::NIO::Selector.backends]
      unless valid_backends.include?(backend)
        raise ArgumentError.new("unsupported IO selector backend: #{backend} (available backends: #{valid_backends.join(', ')})")
      end

      @selector = ::NIO::Selector.new(NIO::Selector.backends.delete(backend))
      @input = Queue.new
      @timeouts = []
      @block = block
      @reactor_size = 0
      @reactor_max = 0
    end

    # Run the internal select loop, using a background thread by default.
    def run(background=true)
      if background
        @thread = Thread.new do
          Puma.set_thread_name "reactor"
          select_loop
        end
      else
        select_loop
      end
    end

    # Add a new client to monitor.
    # The object must respond to #timeout and #timeout_at.
    # Returns false if the reactor is already shut down.
    def add(client)
      @input << client
      @selector.wakeup
      true
    rescue ClosedQueueError, IOError # Ignore if selector is already closed
      false
    end

    # Shutdown the reactor, blocking until the background thread is finished.
    def shutdown
      @input.close
      begin
        @selector.wakeup
      rescue IOError # Ignore if selector is already closed
      end
      @thread&.join
    end

    private

    def select_loop
      begin
        until @input.closed? && @input.empty?
          # Wakeup any registered object that receives incoming data.
          # Block until the earliest timeout or Selector#wakeup is called,
          # or not at all while clients are still waiting to be registered.
          timeout = @input.empty? ? (earliest = @timeouts.first) && earliest.timeout : 0
          @selector.select(timeout) do |monitor|
            wakeup!(monitor.value)
          end

          # Wakeup all objects that timed out.
          timed_out = @timeouts.take_while { |client| client.timeout == 0 }
          timed_out.each { |client| wakeup!(client) }

          until @input.empty?
            client = @input.pop
            register(client) if client.io_ok?
          end
        end
      rescue StandardError => e
        STDERR.puts "Error in reactor loop escaped: #{e.message} (#{e.class})"
        STDERR.puts e.backtrace

        retry
      end

      # Wakeup all remaining objects on shutdown.
      @timeouts.each(&@block)
      @selector.close
    end

    # Start monitoring the object.
    def register(client)
      @selector.register(client.to_io, :r).value = client
      @reactor_size += 1
      @reactor_max = @reactor_size if @reactor_max < @reactor_size
      insert_timeout client
    rescue ArgumentError, IOError
      # unreadable clients raise error when processed by NIO; a client closed
      # between io_ok? and here raises IOError
    end

    # 'Wake up' a monitored object by calling the provided block.
    # Stop monitoring the object if the block returns `true`.
    def wakeup!(client)
      timeout_at = client.timeout_at
      if @block.call client
        @selector.deregister client.to_io
        @reactor_size -= 1
        remove_timeout client, timeout_at
      elsif client.timeout_at != timeout_at
        # still monitored with a new deadline: keep @timeouts sorted
        remove_timeout client, timeout_at
        insert_timeout client
      end
    end

    # @timeouts is kept sorted by timeout_at, so @timeouts.first is always
    # the earliest deadline. Both operations are a binary search plus one
    # Array#insert / #delete_at.
    def insert_timeout(client)
      at = client.timeout_at
      i = @timeouts.bsearch_index { |c| c.timeout_at > at } || @timeouts.size
      @timeouts.insert(i, client)
    end

    # +timeout_at+ is the deadline the client was sorted under; the client
    # itself may already carry a later one.
    def remove_timeout(client, timeout_at)
      i = @timeouts.bsearch_index { |c| c.equal?(client) || c.timeout_at >= timeout_at }
      while i && i < @timeouts.size
        return @timeouts.delete_at(i) if @timeouts[i].equal?(client)
        break unless @timeouts[i].timeout_at == timeout_at
        i += 1
      end
      @timeouts.delete client # not where it was sorted: fall back to a scan
    end
  end
end
