require 'thread'
require 'monitor'

module ActiveSupport
  module Concurrency
    # A share/exclusive lock, otherwise known as a read/write lock.
    #
    # https://en.wikipedia.org/wiki/Readers%E2%80%93writer_lock
    #--
    # Note that a pending Exclusive lock attempt does not block incoming
    # Share requests (i.e., we are "read-preferring"). That seems
    # consistent with the behavior of "loose" upgrades, but may be the
    # wrong choice otherwise: it nominally reduces the possibility of
    # deadlock by risking starvation instead.
    class ShareLock
      include MonitorMixin

      # We track Thread objects, instead of just using counters, because
      # we need exclusive locks to be reentrant, and we need to be able
      # to upgrade share locks to exclusive.


      def initialize
        super()

        @cv = new_cond

        @sharing = Hash.new(0)
        @waiting = {}
        @exclusive_thread = nil
        @exclusive_depth = 0
      end

      # Returns false if +no_wait+ is set and the lock is not
      # immediately available. Otherwise, returns true after the lock
      # has been acquired.
      #
      # +purpose+ and +compatible+ work together; while this thread is
      # waiting for the exclusive lock, it will yield its share (if any)
      # to any other attempt whose +purpose+ appears in this attempt's
      # +compatible+ list. This allows a "loose" upgrade, which, being
      # less strict, prevents some classes of deadlocks.
      #
      # For many resources, loose upgrades are sufficient: if a thread
      # is awaiting a lock, it is not running any other code. With
      # +purpose+ matching, it is possible to yield only to other
      # threads whose activity will not interfere.
      def start_exclusive(purpose: nil, compatible: [], no_wait: false)
        synchronize do
          unless @exclusive_thread == Thread.current
            if busy_for_exclusive?(purpose)
              return false if no_wait

              yield_shares(purpose, compatible) do
                @cv.wait_while { busy_for_exclusive?(purpose) }
              end
            end
            @exclusive_thread = Thread.current
          end
          @exclusive_depth += 1

          true
        end
      end

      # Relinquish the exclusive lock. Must only be called by the thread
      # that called start_exclusive (and currently holds the lock).
      def stop_exclusive(compatible: [])
        synchronize do
          raise "invalid unlock" if @exclusive_thread != Thread.current

          @exclusive_depth -= 1
          if @exclusive_depth == 0
            @exclusive_thread = nil

            yield_shares(nil, compatible) do
              @cv.broadcast
              @cv.wait_while { @exclusive_thread || eligible_waiters?(compatible) }
            end
          end
        end
      end

      def start_sharing(purpose: :share)
        synchronize do
          if @sharing[Thread.current] == 0 && @exclusive_thread != Thread.current && busy_for_sharing?(purpose)
            @cv.wait_while { busy_for_sharing?(purpose) }
          end
          @sharing[Thread.current] += 1
        end
      end

      def stop_sharing
        synchronize do
          if @sharing[Thread.current] > 1
            @sharing[Thread.current] -= 1
          else
            @sharing.delete Thread.current
            @cv.broadcast
          end
        end
      end

      # Execute the supplied block while holding the Exclusive lock. If
      # +no_wait+ is set and the lock is not immediately available,
      # returns +nil+ without yielding. Otherwise, returns the result of
      # the block.
      #
      # See +start_exclusive+ for other options.
      def exclusive(purpose: nil, compatible: [], after_compatible: [], no_wait: false)
        if start_exclusive(purpose: purpose, compatible: compatible, no_wait: no_wait)
          begin
            yield
          ensure
            stop_exclusive(compatible: after_compatible)
          end
        end
      end

      # Execute the supplied block while holding the Share lock.
      def sharing
        start_sharing
        begin
          yield
        ensure
          stop_sharing
        end
      end

      private

      # Must be called within synchronize
      def busy_for_exclusive?(purpose)
        busy_for_sharing?(purpose) ||
          @sharing.size > (@sharing[Thread.current] > 0 ? 1 : 0)
      end

      def busy_for_sharing?(purpose)
        (@exclusive_thread && @exclusive_thread != Thread.current) ||
          @waiting.any? { |t, (_, c)| t != Thread.current && !c.include?(purpose) }
      end

      def eligible_waiters?(compatible)
        @waiting.any? { |t, (p, _)| compatible.include?(p) && @waiting.all? { |t2, (_, c2)| t == t2 || c2.include?(p) } }
      end

      def yield_shares(purpose, compatible)
        loose_shares = @sharing.delete(Thread.current)
        @waiting[Thread.current] = [purpose, compatible] if loose_shares

        begin
          yield
        ensure
          @waiting.delete Thread.current
          @sharing[Thread.current] = loose_shares if loose_shares
        end
      end
    end
  end
end
