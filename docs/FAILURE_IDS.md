Failure IDs
===========

By default, every failure Resque records is assigned a `failure_id`: a UUID
generated once, at failure time, and shared by every configured failure backend
that accepts one.

Why
---

Failures are usually recorded in more than one place - the Redis failed list
plus whatever exception tracking service you use:

``` ruby
Resque::Failure::Multiple.classes = [Resque::Failure::Redis, MyExceptionTracker]
Resque::Failure.backend = Resque::Failure::Multiple
```

Before `failure_id` there was no way to tell that the record in the failed list
and the event in the other service were the *same* failure. Each backend
recorded it independently, with no shared handle. `failure_id` is that handle.


What it is not
--------------

**`failure_id` is not an index, and it does not give you O(1) lookup.** The
failed list is still a list; resolving an id to a position still means scanning
it. Index based addressing is unchanged - `all`, `each`, `requeue` and `remove`
all still take positions, and mean exactly what they meant before.

What the id buys you is a *check*. A tool that lets an operator select a failure
and then act on it can re-read the element immediately before mutating it and
confirm it is still the record that was selected, rather than a different one
that shifted into that position in the meantime:

``` ruby
selected_id = params[:failure_id]

current = Resque::Failure.all(index)
if current && current['failure_id'] == selected_id
  Resque::Failure.remove(index)
else
  # the list moved under us - re-resolve before acting
end
```

This is a read followed by a write, not an atomic operation. The list can still
shift between the two, so the check narrows the window rather than closing it -
it turns "silently acted on the wrong record" into "usually caught it". If you
need a real guarantee, take a lock around your read and write, or do the
compare and the mutation in a single Lua script.


Consuming it
------------

Check for the field **per record** and degrade when it is absent. Failures
recorded before you upgraded do not have one, and neither do failures recorded
by an older Resque, so there is no version check that will save you from this:

``` ruby
Resque::Failure.each do |index, failure|
  if failure['failure_id']
    # correlate, check, whatever you need
  else
    # older record - fall back to index-only behaviour
  end
end
```


Supplying your own
------------------

If you already have an id you would rather use - a trace id, for instance -
pass it to `Resque::Failure.create`:

``` ruby
Resque::Failure.create(
  :exception  => exception,
  :worker     => worker,
  :queue      => queue,
  :payload    => payload,
  :failure_id => current_trace_id
)
```


Turning it off
--------------

Generation is on by default. With it off, `failure_id` is `nil` everywhere and
the payload Resque stores is identical to what it stored before the feature
existed - the key is left out entirely, not set to `nil`:

``` ruby
Resque::Failure.generate_failure_ids = false
```

An explicit `:failure_id` passed to `create` is still assigned, since you asked
for that one by name.

The realistic reason to turn it off is a schema validator somewhere in your
stack that rejects unknown keys in the failure payload.


Writing a backend
-----------------

Backends inherit `failure_id` from `Resque::Failure::Base`, so there is nothing
to add unless you want to report it to your service:

``` ruby
class MyFailure < Resque::Failure::Base
  def save
    MyService.notify(exception, :context => { :failure_id => failure_id })
  end
end
```

`Base` is what generates the id, in `initialize`, so it is available for the
whole life of the object - `save` included. It is `nil` only when generation is
turned off, so guard with `if failure_id` if you support that.

A backend that does not subclass `Base` owns its own id. Defining `failure_id=`
does not get you one generated; the writer is how a backend *receives* an id
that something else already made. Concretely, such a backend is handed an id
when it runs under `Resque::Failure::Multiple`, which is a `Base` and pushes its
own id down into every child that has a writer, or when the caller passes
`:failure_id` to `create`. As the only backend, with no id named by the caller,
it gets nothing - generate one in your own `initialize` if you want it. A
backend with no writer at all is simply skipped, and keeps working.

Since the id exists to tie one failure to its records in other backends, this
mostly does not come up: the case where correlation is the point is the
`Multiple` case, which is covered. Subclassing `Base` is the easy way out
either way.
