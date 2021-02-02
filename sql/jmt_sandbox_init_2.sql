begin;

create table if not exists sandbox.problem_vote_events (
  problem_vote_id int generated always as identity primary key,
  problem_id int references sandbox.problems (problem_id),
  user_id int references sandbox.users (user_id),
  user_is_verified boolean,
  vote_ts timestamptz,
  signed_vote int,
  num_tokens_spent int
);

create table if not exists sandbox.solution_vote_events (
  solution_vote_id int generated always as identity primary key,
  solution_id int references sandbox.solutions (solution_id),
  user_id int references sandbox.users (user_id),
  user_is_verified boolean,
  vote_ts timestamptz,
  signed_vote int,
  num_tokens_spent int,
  is_reclaim boolean default 'false'
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

-- Walk through problem_vote_events and tally total number of votes cast on a particular problem, by a particular user. Used to determine nth vote cost.
create or replace function sandbox.count_problem_votes(_user_id int, _problem_id int, out _vote_count int)
language plpgsql
as $func$
begin
  -- Use absolute value of _signed_vote since "down votes" are represented as negative integers.
  select coalesce(sum(abs(signed_vote)), 0) into _vote_count
  from sandbox.problem_vote_events
  where problem_id = _problem_id
  and user_id = _user_id;
end;
$func$;

-- Walk through solution_vote_events and tally total number of votes cast on a particular solution, by a particular user. Used to determine nth vote cost.
create or replace function sandbox.count_solution_votes(_user_id int, _solution_id int, out _vote_count int)
language plpgsql
as $func$
declare
  _all_votes int;
  _reclaim_offset int;
begin
  -- Use absolute value of _signed_vote since "down votes" are represented as negative integers.
  select coalesce(sum(abs(signed_vote)), 0) into _all_votes
  from sandbox.solution_vote_events
  where solution_id = _solution_id
  and user_id = _user_id;
  -- Subtract reclaimed votes
  select coalesce(sum(abs(signed_vote)), 0) into _reclaim_offset
  from sandbox.solution_vote_events
  where
    solution_id = _solution_id and
    user_id = _user_id and 
    is_reclaim = 'true';
  -- Vote count is used to determine the nth vote's cost for a user.
  _vote_count := _all_votes - _reclaim_offset;
end;
$func$;

-- Return the cost of placing n more votes per quadratic voting math. A signed_vote is not necessarily a single vote, but rather a positive/negative quantity of votes.
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

-- The procedures for adding votes will throw if a user attempts to over-spend token balance. In order to add dummy votes (testing only), this function returns a voting plan that mocks client activity, checking balance constraints ahead of time.
create or replace function sandbox.make_dummy_problem_voting_plan(_starting_token_balance int, _balance_floor int, out _problem_voting_plan int[][])
language plpgsql
as $func$
declare
  _arr_all_problem_ids int[] := array(select problem_id from sandbox.problems);
  _num_problems int := array_length(_arr_all_problem_ids, 1);
  _selected_problem int;
  _arr_selected_problem_ids int[];
  _token_balance int := _starting_token_balance;
  _max_num_votes_desired int;
  _num_votes_attempted int;
  _is_up_vote boolean;
  _vote_cost int;
begin
  -- Grab random problem and attempt random number of votes until balance is less than balance_floor, or too low for 1 additional vote.
  <<outer_loop>>
  loop
    -- Exit loop once token balance drops lower than balance floor, or every problem has been voted on.
    if _token_balance < _balance_floor or array_length(_arr_all_problem_ids, 1) = array_length(_arr_selected_problem_ids, 1) then
      raise notice 'Dropped below floor or voted on everything.';
      exit outer_loop;
    end if;
    -- Choose random problem.
    _selected_problem := _arr_all_problem_ids[sandbox.random(1, array_length(_arr_all_problem_ids, 1))];
    raise notice 'Selected problem: %', _selected_problem;
    -- Skip current iteration (outer loop) if we looked at this problem already.
    if _selected_problem = any(_arr_selected_problem_ids) then
      raise notice 'Been here done this.';
      continue outer_loop;
    else
      _arr_selected_problem_ids := _arr_selected_problem_ids || _selected_problem;
    end if;
    -- Attempt max votes desired, or max minus "counter" in unconditional loop.
    -- During testing users did not have > 400 tokens, so max 11 votes possible.
    _max_num_votes_desired := sandbox.random(1, 11);
    _num_votes_attempted := _max_num_votes_desired;
    _is_up_vote := not (sandbox.random(0,1) = 0);
    <<inner_loop>>
    loop
      -- We know _num_previous_votes is 0 because we're preventing more than 1 voting event per per problem, above.
      _vote_cost := sandbox.calculate_vote_cost(_num_previous_votes := 0, _signed_vote := _num_votes_attempted);
      if _vote_cost > _token_balance then
        _num_votes_attempted := _num_votes_attempted - 1;
      else
        -- Adjust token balance.
        _token_balance := _token_balance - _vote_cost;
        -- Add to voting plan array (adjusted for up/down vote) and exit inner loop.
        if _is_up_vote then
          _problem_voting_plan := _problem_voting_plan || array[[_selected_problem, _num_votes_attempted]];
        else
          _problem_voting_plan := _problem_voting_plan || array[[_selected_problem, _num_votes_attempted * -1]];
        end if;
        raise notice 'Vote added to plan.';
        exit inner_loop;
      end if;
      if _num_votes_attempted < 1 then
        raise notice 'Insufficient balance for 1 additional vote.';
        exit outer_loop;
      end if;
    end loop;
  end loop;
  raise notice 'All loops terminated.';
end;
$func$;

create or replace function sandbox.make_dummy_solution_voting_plan(_problem_voting_plan int[][], out _solution_voting_plan int[][])
language plpgsql
as $func$
declare
  _paired_solution_ids int[];
  _num_voting_attempts int;
  _max_votes_possible int;
  _selected_solution int;
  _num_votes int;
  _is_down_vote boolean;
begin
  -- Avoid returning null value by setting value as empty array.
  _solution_voting_plan := array[]::int[];
  -- Loop over problem voting plan array and select corresponding solutions (ids) into new array.
  for counter in 1..array_length(_problem_voting_plan, 1)
  loop
    _paired_solution_ids := array(select solution_id from sandbox.solutions where problem_id = _problem_voting_plan[counter][1]);
    -- Pick random number of voting attempts, 0 - max number of corresponding solutions.
    _num_voting_attempts := sandbox.random(0, array_length(_paired_solution_ids, 1));
    _max_votes_possible := _problem_voting_plan[counter][2];
    -- Loop through paired solutions array choosing solutions at random, until we've attempted all votes we want or can afford.
    <<inner_loop>>
    loop
      if _num_voting_attempts < 1 or _max_votes_possible < 1 then
        exit inner_loop;
      end if;
      -- Pick random number of actual votes to place, 1 - max votes possible, and random solution on which to vote.
      _num_votes := sandbox.random(1, _max_votes_possible);
      _selected_solution := sandbox.random(1, array_length(_paired_solution_ids, 1));
      -- Note, 33% chance... Downvotes are likely less common in solutions compared to problems.
      _is_down_vote := not (sandbox.random(0,2) = 0);
      if _is_down_vote then
        _solution_voting_plan := _solution_voting_plan || array[[_paired_solution_ids[_selected_solution], _num_votes * -1]];
      else
        _solution_voting_plan := _solution_voting_plan || array[[_paired_solution_ids[_selected_solution], _num_votes]];
      end if;
      _max_votes_possible := _max_votes_possible - _num_votes;
      _num_voting_attempts := _num_voting_attempts - 1;
    end loop;
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
    raise notice 'Vote cost: %, and Num tokens: %, and Num previous votes: %', _vote_cost, _selected_user.num_d365_tokens, _num_previous_votes;
    raise exception sqlstate '90001' using message = 'Insufficient d365 token balance';
  else
    -- Deduct tokens from user's balance.
    update sandbox.users
    set num_d365_tokens = num_d365_tokens - _vote_cost
    where user_id = _user_id;
    -- Record vote (purchase).
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

create or replace procedure sandbox.add_solution_vote(_user_id int, _solution_id int, _signed_vote int)
language plpgsql
as $proc$
declare
  _selected_user sandbox.users%rowtype;
  _selected_solution sandbox.solutions%rowtype;
  _available_solution_tokens int;
  _ts_now timestamptz := now();
  _num_previous_votes int := sandbox.count_solution_votes(_user_id, _solution_id);
  _vote_cost int := sandbox.calculate_vote_cost(_num_previous_votes, _signed_vote);
begin
  select * into _selected_user
  from sandbox.users
  where user_id = _user_id;
  -- Grab corresponding problem_id so we can check solution token balance
  select * into _selected_solution
  from sandbox.solutions
  where solution_id = _solution_id;
  -- Get balance of solution tokens for given user and problem_id
  select solution_tokens into _available_solution_tokens
  from sandbox.solution_tokens
  where
    user_id = _user_id and
    problem_id = _selected_solution.problem_id;
  -- Check/throw if user has an insufficient token balance.
  if _vote_cost > _available_solution_tokens then
    raise exception sqlstate '90001' using message = 'Insufficient solution token balance';
  else
    -- Deduct tokens from user's balance.
    update sandbox.solution_tokens
    set solution_tokens = solution_tokens - _vote_cost
    where
      user_id = _user_id and 
      problem_id = _selected_solution.problem_id;
    -- Record vote (purchase).
    insert into sandbox.solution_vote_events(solution_id, user_id, user_is_verified, vote_ts, signed_vote, num_tokens_spent)
    values (_solution_id, _user_id, _selected_user.is_verified, _ts_now, _signed_vote, _vote_cost);
  end if;
end;
$proc$;

create or replace procedure sandbox.insert_dummy_votes()
language plpgsql
as $proc$
declare
  _u record;
  _random_balance_floor int;
  _problem_voting_plan int[][];
  _solution_voting_plan int[][];
begin
  -- Loop(1) over users.
  for _u in
    select user_id, num_d365_tokens
    from sandbox.users 
  loop
    -- Make problem voting plan & solution voting plan arrays.
    _random_balance_floor := _u.num_d365_tokens * sandbox.random(1, 100)::decimal/100;
    raise notice 'Loop 1, user_id: %, with % tokens, and balance floor: %', _u.user_id, _u.num_d365_tokens, _random_balance_floor;

    _problem_voting_plan := sandbox.make_dummy_problem_voting_plan(_starting_token_balance := _u.num_d365_tokens, _balance_floor := _random_balance_floor);
    raise notice 'Finished problem voting plan for user %: %', _u.user_id, _problem_voting_plan;

    _solution_voting_plan := sandbox.make_dummy_solution_voting_plan(_problem_voting_plan := _problem_voting_plan);
    raise notice 'Finished solution voting plan for user %: %', _u.user_id, _solution_voting_plan;

    -- Loop(2) over problem voting plan array to cast votes.
    for counter in 1..array_length(_problem_voting_plan, 1)
    loop
      call sandbox.add_problem_vote(_user_id := _u.user_id, _problem_id := _problem_voting_plan[counter][1], _signed_vote := _problem_voting_plan[counter][2]);
      raise notice 'Loop 2, problem vote added: %', _problem_voting_plan[counter:counter][1:2];
    end loop;

    -- Loop(3) over solution voting plan array to cast votes. Unlike problem voting plans, solution voting plans can be empty (no solution votes).

    -- TODO: Fix the following, not catching empty array???

    raise notice 'ARRAY LENGTH: %', array_length(_solution_voting_plan, 1);
    if array_length(_solution_voting_plan, 1) > 0 then
      for counter in 1..array_length(_solution_voting_plan, 1)
      loop
        call sandbox.add_solution_vote(_user_id := _u.user_id, _solution_id := _solution_voting_plan[counter][1], _signed_vote := _solution_voting_plan[counter][2]);
        raise notice 'Loop 2, solution vote added: %', _solution_voting_plan[counter:counter][1:2];
      end loop;
    end if;

  end loop;
end;
$proc$;

-- *
-- * Sandbox
-- *

-- call sandbox.add_problem_vote(_user_id := 1, _problem_id := 1, _signed_vote := 2);

-- call sandbox.add_solution_vote(_user_id := 1, _solution_id := 1, _signed_vote := 2);

call sandbox.insert_dummy_votes();

select * from sandbox.problem_vote_events;

select * from sandbox.solution_vote_events;

-- select * from sandbox.solution_tokens;

-- select num_d365_tokens from sandbox.users where user_id = 1;

-- Commit or Rollback
rollback;

