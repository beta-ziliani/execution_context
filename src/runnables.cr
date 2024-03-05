require "./global_queue"

abstract class ExecutionContext
  # Local queue or runnable fibers for schedulers.
  # First-in, first-out semantics (FIFO).
  # Single producer, multiple consumers thread safety.
  #
  # Private to an execution context scheduler, except for stealing methods that
  # can be called from any thread in the execution context.
  class Runnables(N)
    def initialize(@global_queue : GlobalQueue)
      @head = Atomic(UInt32).new(0)
      @tail = Atomic(UInt32).new(0)
      @buffer = uninitialized Fiber[N]
    end

    @[AlwaysInline]
    def capacity : Int32
      N
    end

    # Tries to push fiber on the local runnable queue. If the run queue is full,
    # pushes fiber on the global queue, which will grab the global lock.
    #
    # Executed only by the owner.
    def push(fiber : Fiber) : Nil
      loop do
        head = @head.get(:acquire) # sync with consumers
        tail = @tail.get(:acquire)

        if (tail &- head) < N
          # put fiber to local queue
          @buffer.to_unsafe[tail % N] = fiber

          # make the fiber available for consumption
          @tail.set(tail &+ 1, :release)
          return
        end

        return if push_slow(fiber, head, tail)

        # failed to advance head (another scheduler stole fibers),
        # the queue isn't full, now the push above must succeed
      end
    end

    private def push_slow(fiber : Fiber, head : UInt32, tail : UInt32) : Bool
      n = (tail &- head) // 2
      raise "BUG: queue is not full" if n != N // 2

      # first, try to grab a batch of fibers from local queue
      batch = uninitialized Fiber[N]
      n.times do |i|
        batch.to_unsafe[i] = @buffer.to_unsafe[(head &+ i) % N]
      end
      _, success = @head.compare_and_set(head, head &+ n, :acquire_release, :acquire)
      return false unless success

      # append fiber to the batch
      batch.to_unsafe[n] = fiber

      # link the fibers
      n.times do |i|
        batch.to_unsafe[i].schedlink = batch.to_unsafe[i &+ 1]
      end
      queue = Queue.new(batch.to_unsafe[0], batch.to_unsafe[n])

      # now put the batch on global queue (grabs the global lock)
      @global_queue.push(pointerof(queue), (n &+ 1).to_i32)

      true
    end

    # Tries to enqueue all the fibers in `queue` into the local queue. If the
    # queue is full, the overflow will be pushed to the global queue; in that
    # case this will temporarily acquire the global queue lock.
    #
    # Executed only by the owner.
    def bulk_push(queue : Queue*, size : Int32) : Nil
      tail = @tail.get(:acquire) # sync with other consumers
      head = @head.get(:relaxed)

      while !queue.value.empty? && (tail &- head) < N
        fiber = queue.value.pop
        @buffer.to_unsafe[tail % N] = fiber
        tail &+= 1
        size &-= 1
      end

      # make the fibers available for consumption
      @tail.set(tail, :release)

      # put any overflow on global queue
      @global_queue.push(queue, size) if size > 0
    end

    # Dequeues the next runnable fiber from the local queue.
    #
    # Executed only by the owner.
    # TODO: rename as `#shift?`
    def get? : Fiber?
      head = @head.get(:acquire) # sync with other consumers

      loop do
        tail = @tail.get(:relaxed)
        return if tail == head

        fiber = @buffer.to_unsafe[head % N]
        head, success = @head.compare_and_set(head, head &+ 1, :acquire_release, :acquire)
        return fiber if success
      end
    end

    # Steals half the fibers from the local queue of `src` and puts them onto
    # the local queue. Returns one of the stolen fibers, or `nil` on failure.
    #
    # Only executed from the owner (when the local queue is empty).
    def steal_from(src : Runnables) : Fiber?
      tail = @tail.get(:acquire)
      n = src.grab(@buffer.to_unsafe, tail)
      return if n == 0

      n &-= 1
      fiber = @buffer.to_unsafe[(tail &+ n) % N]
      return fiber if n == 0

      head = @head.get(:acquire) # sync with consumers
      raise "BUG: local queue overflow" if tail &- head &+ n >= N

      # make the fibers available for consumption
      @tail.set(tail &+ n, :release)

      fiber
    end

    # Grabs a batch of fibers from local queue into `buffer` (normally the ring
    # buffer of another `Runnables`) starting at `buffer_head`. Returns number
    # of grabbed fibers.
    #
    # Can be executed by any scheduler.
    protected def grab(buffer : Fiber*, buffer_head : UInt32) : UInt32
      head = @head.get(:acquire) # sync with other consumers

      loop do
        tail = @tail.get(:acquire) # sync with the producer
        n = (tail &- head) // 2

        return 0_u32 if n == 0 # queue is empty
        next if n > N // 2 # read inconsistent head and tail

        n.times do |i|
          fiber = @buffer.to_unsafe[(head &+ i) % N]
          buffer[(buffer_head &+ i) % N] = fiber
        end

        head, success = @head.compare_and_set(head, head &+ n, :acquire_release, :acquire)
        return n if success
      end
    end

    # @[AlwaysInline]
    # def empty? : Bool
    #   head = @head.get(:relaxed)
    #   tail = @tail.get(:relaxed)
    #   tail &- head == 0
    # end
  end
end
