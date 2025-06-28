type t = {
  requests_per_minute : int;
  requests : float Queue.t;
  mutex : Eio.Mutex.t;
}

let create requests_per_minute =
  {
    requests_per_minute;
    requests = Queue.create ();
    mutex = Eio.Mutex.create ();
  }

let acquire t clock =
  Eio.Mutex.use_rw t.mutex ~protect:true @@ fun () ->
  let now = Eio.Time.now clock in
  (* Remove requests older than 1 minute *)
  let one_minute_ago = now -. 60.0 in
  while
    (not (Queue.is_empty t.requests)) && Queue.peek t.requests < one_minute_ago
  do
    ignore (Queue.pop t.requests)
  done;

  (* If we've made too many requests, wait *)
  if Queue.length t.requests >= t.requests_per_minute then (
    let oldest_request = Queue.peek t.requests in
    let wait_time = 60.0 -. (now -. oldest_request) in
    if wait_time > 0. then Eio.Time.sleep clock wait_time;

    Queue.push now t.requests)
