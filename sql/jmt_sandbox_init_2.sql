begin;

create table if not exists sandbox.problem_vote_events (
  problem_vote_id int generated always as identity primary key,
  problem_id int references sandbox.problems (problem_id),
  user_id int references sandbox.users (user_id),
  user_is_verified boolean,
  vote_ts timestamptz,
  signed_vote int,
  num_tokens_spent int,
  is_forced_reclaim boolean default 'false',
  is_replay_vote boolean default 'false'
);

create table if not exists sandbox.solution_tokens (
  user_id int references sandbox.users (user_id),
  problem_id int references sandbox.problems (problem_id),
  solution_tokens int,
  unique (user_id, problem_id)
);

-- *
-- * Functions
-- *

create or replace function sandbox.count_problem_votes(_user_id int, _problem_id int, out _vote_count int)
language plpgsql
as $func$
begin
  -- Use absolute value of _signed_vote since "down votes" are represented as negative integers.
  select coalesce(sum(abs(signed_vote)), 0) into _vote_count
  from sandbox.problem_vote_events
  where
    problem_id = _problem_id and
    user_id = _user_id;
end;
$func$;

create or replace function sandbox.calculate_vote_cost(_num_previous_votes int, _signed_vote int, out _vote_cost int)
language plpgsql
as $func$
declare
  _nth_vote int;
begin
  _vote_cost := 0;
  -- Use absolute value of _signed_vote since "down votes" are represented as negative integers.
  for counter in 1..abs(_signed_vote) loop
    _nth_vote := _num_previous_votes + counter;
    _vote_cost := _vote_cost + power(_nth_vote, 2);
  end loop;
end;
$func$;

-- *
-- * Procedures
-- *

create or replace procedure sandbox.add_problem_vote(_user_id int, _problem_id int, _signed_vote int)
language plpgsql
as $proc$
declare
  _selected_user sandbox.users%rowtype;
  _ts_now timestamptz := now();
  _num_previous_votes int := sandbox.count_problem_votes(_user_id, _problem_id);
  _vote_cost int := sandbox.calculate_vote_cost(_num_previous_votes, _signed_vote);
begin
  select * into _selected_user
  from sandbox.users
  where user_id = _user_id;
  -- Check/throw if user has an insufficient token balance.
  if _vote_cost > _selected_user.num_d365_tokens then
    raise exception sqlstate '90001' using message = 'Insufficient d365 token balance';
  else
    -- Deduct tokens from user's balance.
    update sandbox.users
    set num_d365_tokens = num_d365_tokens - _vote_cost
    where user_id = _user_id;
    -- Record vote (purchase) to problem vote "events" table.
    insert into sandbox.problem_vote_events(problem_id, user_id, user_is_verified, vote_ts, signed_vote, num_tokens_spent)
    values (_problem_id, _user_id, _selected_user.is_verified, _ts_now, _signed_vote, _vote_cost);
    -- If problem has been "up-voted" credit user equal num of solution tokens.
    if _signed_vote > 0 then
      insert into sandbox.solution_tokens(user_id, problem_id, solution_tokens)
      values (_user_id, _problem_id, _vote_cost)
      on conflict (user_id, problem_id)
      do update set solution_tokens = sandbox.solution_tokens.solution_tokens + excluded.solution_tokens;
    end if;
  end if;
end;
$proc$;

-- *
-- * Sandbox
-- *

-- Problem Votes
call sandbox.add_problem_vote(_user_id := 1, _problem_id := 1, _signed_vote := 2);

-- Display
-- select *
-- from sandbox.users;

-- select *
-- from sandbox.problems;

-- select *
-- from sandbox.solutions;

-- select *
-- from sandbox.links;

select * from sandbox.problem_vote_events;

select * from sandbox.solution_tokens;

select num_d365_tokens from sandbox.users where user_id = 1;

-- Commit or Rollback
rollback;

