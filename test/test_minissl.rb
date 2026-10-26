require_relative "helper"

require "puma/minissl" if ::Puma::HAS_SSL

class TestMiniSSL < PumaTest

  if Puma.jruby?
    def test_raises_with_invalid_keystore_file
      ctx = Puma::MiniSSL::Context.new

      exception = assert_raises(ArgumentError) { ctx.keystore = "/no/such/keystore" }
      assert_equal("Keystore file '/no/such/keystore' does not exist", exception.message)
    end

    def test_raises_with_unreadable_keystore_file
      ctx = Puma::MiniSSL::Context.new

      File.stub(:exist?, true) do
        File.stub(:readable?, false) do
          exception = assert_raises(ArgumentError) { ctx.keystore = "/unreadable/keystore" }
          assert_equal("Keystore file '/unreadable/keystore' is not readable", exception.message)
        end
      end
    end
  else
    def test_raises_with_invalid_key_file
      ctx = Puma::MiniSSL::Context.new

      exception = assert_raises(ArgumentError) { ctx.key = "/no/such/key" }
      assert_equal("Key file '/no/such/key' does not exist", exception.message)
    end

    def test_raises_with_unreadable_key_file
      ctx = Puma::MiniSSL::Context.new

      File.stub(:exist?, true) do
        File.stub(:readable?, false) do
          exception = assert_raises(ArgumentError) { ctx.key = "/unreadable/key" }
          assert_equal("Key file '/unreadable/key' is not readable", exception.message)
        end
      end
    end

    def test_raises_with_invalid_cert_file
      ctx = Puma::MiniSSL::Context.new

      exception = assert_raises(ArgumentError) { ctx.cert = "/no/such/cert" }
      assert_equal("Cert file '/no/such/cert' does not exist", exception.message)
    end

    def test_raises_with_unreadable_cert_file
      ctx = Puma::MiniSSL::Context.new

      File.stub(:exist?, true) do
        File.stub(:readable?, false) do
          exception = assert_raises(ArgumentError) { ctx.key = "/unreadable/cert" }
          assert_equal("Key file '/unreadable/cert' is not readable", exception.message)
        end
      end
    end

    def test_raises_with_invalid_key_pem
      ctx = Puma::MiniSSL::Context.new

      exception = assert_raises(ArgumentError) { ctx.key_pem = nil }
      assert_equal("'key_pem' is not a String", exception.message)
    end

    def test_raises_with_unreadable_ca_file
      ctx = Puma::MiniSSL::Context.new

      File.stub(:exist?, true) do
        File.stub(:readable?, false) do
          exception = assert_raises(ArgumentError) { ctx.ca = "/unreadable/cert" }
          assert_equal("ca file '/unreadable/cert' is not readable", exception.message)
        end
      end
    end

    def test_raises_with_invalid_cert_pem
      ctx = Puma::MiniSSL::Context.new

      exception = assert_raises(ArgumentError) { ctx.cert_pem = nil }
      assert_equal("'cert_pem' is not a String", exception.message)
    end

    def test_read_nonblock_returns_data_sent_before_close_notify
      require "openssl"
      require "socket"
      examples = File.expand_path "../examples/puma", __dir__
      ctx = Puma::MiniSSL::Context.new
      ctx.key  = "#{examples}/puma_keypair.pem"
      ctx.cert = "#{examples}/cert_puma.pem"
      ctx.verify_mode = Puma::MiniSSL::VERIFY_NONE
      srv_io, cli_io = UNIXSocket.pair
      sock = Puma::MiniSSL::Socket.new srv_io, Puma::MiniSSL::Engine.server(Puma::MiniSSL::SSLContext.new(ctx))

      client_ctx = OpenSSL::SSL::SSLContext.new
      client_ctx.verify_mode = OpenSSL::SSL::VERIFY_NONE
      client = OpenSSL::SSL::SSLSocket.new cli_io, client_ctx
      client.sync_close = true
      request = "GET / HTTP/1.0\r\n\r\n"
      thread = Thread.new do
        client.connect
        client.write request
        client.close # close_notify follows the request in the same socket read
      end

      data = nil
      deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + 10
      while data.nil?
        begin
          data = sock.read_nonblock 16_384 # drives the handshake, then returns the request
        rescue IO::WaitReadable
          flunk "timed out waiting for the request" if Process.clock_gettime(Process::CLOCK_MONOTONIC) > deadline
          srv_io.wait_readable 0.1
        end
      end
      thread.join

      assert_equal request, data
      assert_raises(EOFError) { sock.read_nonblock 16_384 }
    ensure
      thread&.join
      srv_io&.close
    end

    def test_raises_with_invalid_key_password_command
      ctx = Puma::MiniSSL::Context.new
      ctx.key_password_command = '/unreadable/decrypt_command'

      assert_raises(Errno::ENOENT) { ctx.key_password }
    end
  end
end if ::Puma::HAS_SSL
