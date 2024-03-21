module ExecutionContext
  module Scheduler
    @[AlwaysInline]
    def self.current : Scheduler
      Thread.current.current_scheduler
    end

    abstract def execution_context : ExecutionContext

    # TODO: move to ExecutionContext
    abstract def event_loop : Crystal::EventLoop

    # Instantiates a Fiber and enqueues it into the scheduler's local queue.
    @[AlwaysInline]
    def spawn(*, name : String? = nil, &block : ->) : Fiber
      Fiber.new(name, execution_context, &block).tap { |fiber| enqueue(fiber) }
    end

    @[Deprecated]
    @[AlwaysInline]
    abstract def spawn(*, name : String? = nil, same_thread : Bool, &block : ->) : Fiber

    # Suspends the execution of the current fiber and resumes the next runnable
    # fiber.
    #
    # Unsafe. Must only be called on `ExecutionContext.current`. Prefer
    # `ExecutionContext.reschedule` instead.
    #
    # FIXME: should the method be `protected` (?)
    protected abstract def enqueue(fiber : Fiber) : Nil

    # Suspends the execution of the current fiber and resumes the next runnable
    # fiber.
    #
    # Unsafe. Must only be called on `ExecutionContext.current`. Prefer
    # `ExecutionContext.reschedule` instead.
    protected abstract def reschedule : Nil

    # Suspends the execution of the current fiber and resumes `fiber`.
    #
    # The current fiber will never be resumed; you're responsible to reenqueue
    # it.
    #
    # Handles thread safety around fiber stacks: locks the GC to not start a
    # collection while we're switching context, releases the stack of a dead
    # fiber; as well as validating that `fiber` can indeed be resumed.
    #
    # Unsafe. Must only be called on `ExecutionContext.current`. Caller must
    # ensure that the fiber indeed belongs to the current execution context.
    # Prefer `ExecutionContext.resume` instead.
    #
    # TODO: rename as `#swapcontext` and have a `#resume` that calls
    #       `#validate_resumable` then `#swapcontext`.
    # TODO: consider making it a class method (?)
    protected def resume(fiber : Fiber) : Nil
      validate_resumable(fiber)

      GC.lock_read
      current_fiber = thread.current_fiber
      {% unless flag?(:interpreted) %}
        thread.dead_fiber = current_fiber if current_fiber.dead?
      {% end %}
      thread.current_fiber = fiber
      Fiber.swapcontext(pointerof(current_fiber.@context), pointerof(fiber.@context))
      GC.unlock_read

      # we switched context so we can't trust `self` anymore (it is the
      # scheduler that rescheduled `fiber` which may be another scheduler) as
      # well as any other local or instance variables (e.g. we must resolve
      # `Thread.current` again)

      {% unless flag?(:interpreted) %}
        if fiber = Thread.current.dead_fiber?
          fiber.execution_context.stack_pool.release(fiber.@stack)
        end
      {% end %}
    end

    # Validates that the current fiber can be resumed (e.g. not dead, has saved
    # its context), and aborts the process otherwise.
    private abstract def validate_resumable(fiber : Fiber) : Nil
  end
end
