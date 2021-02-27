begin;

create schema if not exists sandbox;

create table if not exists sandbox.lorem (
  word text
);

create table if not exists sandbox.users (
  user_id int generated always as identity primary key,
  -- Default one token for each day that has elapsed since "go-live" date.
  num_d365_tokens int default (current_date - date '2020-01-01'),
  email_address citext not null unique,
  signin_code char(6) unique,
  signout_ts timestamptz default now(),
  non_verified_mailing_address text,
  verified_mailing_address text,
  verification_code_requested_on timestamptz,
  verification_code_expiration timestamptz,
  verification_code text,
  is_verified boolean default 'false',
  account_updates smallint default 0,
  no_sql jsonb
);

create table if not exists sandbox.problems (
  problem_id int generated always as identity primary key,
  per_year_id int,
  date_created timestamptz,
  problem_title text,
  problem_description text,
  problem_tags text[]
);

create table if not exists sandbox.solutions (
  solution_id int generated always as identity primary key,
  problem_id int references sandbox.problems (problem_id),
  per_problem_id int,
  date_created timestamptz,
  solution_title text,
  solution_description text,
  solution_tags text[],
  no_sql jsonb
);

create table if not exists sandbox.links (
  link_id int generated always as identity primary key,
  problem_id int references sandbox.problems (problem_id),
  solution_id int references sandbox.solutions (solution_id),
  link_title text,
  link_url text
);

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

create table if not exists sandbox.problem_rank_history (
  problem_id int references sandbox.problems (problem_id),
  historical_date date default current_date,
  historical_rank int,
  total_votes int
);

create table if not exists sandbox.solution_rank_history (
  problem_id int references sandbox.problems (problem_id),
  solution_id int references sandbox.solutions (solution_id),
  historical_date date default current_date,
  historical_rank int,
  total_votes int
);

create table if not exists sandbox.delegated_tokens (
  recipient_user_id int references sandbox.users (user_id),
  delegating_user_id int references sandbox.users (user_id),
  delegation_ts timestamptz default now()
);

create table if not exists sandbox.representatives (
  representative_id int generated always as identity primary key,
  is_currently_serving boolean,
  full_name text,
  us_state text,
  district_number smallint,
  no_sql jsonb
);

-- *
-- * Views
-- *

create materialized view if not exists sandbox.problem_rank
as
  select 
    problem_id, 
    rank() over (
      order by sum(sandbox.problem_vote_events.signed_vote) desc
    ), 
    sum(sandbox.problem_vote_events.signed_vote) as total_votes
  from sandbox.problem_vote_events
  group by sandbox.problem_vote_events.problem_id
  order by rank
with no data;

create unique index idx_problem_rank on sandbox.problem_rank(problem_id);

create materialized view if not exists sandbox.solution_rank
as
  select 
    problem_id, 
    sandbox.solutions.solution_id,
    rank() over (
      partition by sandbox.solutions.problem_id
      order by sum(sandbox.solution_vote_events.signed_vote) desc
    ), 
    sum(sandbox.solution_vote_events.signed_vote) as total_votes
  from sandbox.solutions
  join sandbox.solution_vote_events on sandbox.solutions.solution_id = sandbox.solution_vote_events.solution_id
  group by sandbox.solutions.problem_id, sandbox.solutions.solution_id
with no data;

create unique index idx_solution_rank on sandbox.solution_rank(solution_id);

-- *
-- * Functions
-- *

create or replace function sandbox.random(_a int, _b int)
-- Returns a random number within provided range.
returns int
language sql
as $func$
  select _a + ((_b - _a) * random())::int;
$func$;

create or replace function sandbox.random(_a timestamptz, _b timestamptz)
-- Overload sandbox.random
-- Returns a timestamp within provided range.
returns timestamptz
language sql
as $func$
  select
    _a + sandbox.random(0, extract(epoch from (_b - _a))::int) * interval '1 sec';
$func$;

create or replace function sandbox.make_lorem(_len int)
returns text
language sql
as $func$
  with words(w) as 
  (
    select word
    from sandbox.lorem
    order by random()
    limit _len
  )
  select string_agg(w, ' ')
  from words;
$func$;

create or replace function sandbox.make_numeric_serial()
returns char(6)
language plpgsql
as $func$
declare
  _serial_string char(6) = '';
  _i int;
  _char_pool char(10) = '0123456789';
begin
  for _i in 1..6 loop
    _serial_string = _serial_string || substr(_char_pool, int4(floor(random() * length(_char_pool))) + 1, 1);
  end loop;
return lower(_serial_string);
end;
$func$;

create or replace function sandbox.count_problems_in_year(_year int, out num_problems int)
language plpgsql
as $func$
begin
  select count(*) into num_problems
  from sandbox.problems
  where extract(year from date_created)::int = _year;
end;
$func$;

create or replace function sandbox.count_solutions_in_problem(_problem_id int, out _num_solutions int)
language plpgsql
as $func$
begin
  select count(*) into _num_solutions
  from sandbox.solutions
  where problem_id = _problem_id;
end;
$func$;

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
      exit outer_loop;
    end if;
    -- Choose random problem.
    _selected_problem := _arr_all_problem_ids[sandbox.random(1, array_length(_arr_all_problem_ids, 1))];
    -- Skip current iteration (outer loop) if we looked at this problem already.
    if _selected_problem = any(_arr_selected_problem_ids) then
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
        exit inner_loop;
      end if;
      if _num_votes_attempted < 1 then
        exit outer_loop;
      end if;
    end loop;
  end loop;
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
  _is_up_vote boolean;
begin
  -- Avoid returning null value by setting value as empty array.
  _solution_voting_plan := array[]::int[];
  -- Loop over problem voting plan array and select corresponding solutions (ids) into new array.
  for counter in 1..array_length(_problem_voting_plan, 1)
  loop
    _paired_solution_ids := array(
      select solution_id 
      from sandbox.solutions 
      where 
        _problem_voting_plan[counter][2] > 0 and
        problem_id = _problem_voting_plan[counter][1]
    );
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
      _is_up_vote := not (sandbox.random(0,2) = 0);
      if _is_up_vote then
        _solution_voting_plan := _solution_voting_plan || array[[_paired_solution_ids[_selected_solution], _num_votes]];
      else
        _solution_voting_plan := _solution_voting_plan || array[[_paired_solution_ids[_selected_solution], _num_votes * -1]];
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

create or replace procedure sandbox.insert_lorem_text()
language plpgsql
as $proc$
begin
  -- Temporary table 'w', with 'word' column.
  with w(word) as (
    -- Fill word column with lorem ipsum.
    select
      regexp_split_to_table('Lorem ipsum dolor sit amet, consectetur adipiscing elit, sed do eiusmod tempor incididunt ut labore et dolore magna aliqua. Ut enim ad minim veniam, quis nostrud exercitation ullamco laboris nisi ut aliquip ex ea commodo consequat. Duis aute irure dolor in reprehenderit in voluptate velit esse cillum dolore eu fugiat nulla pariatur. Excepteur sint occaecat cupidatat non proident, sunt in culpa qui officia deserunt mollit anim id est laborum.', '[\s., ]')
    union
    select
      regexp_split_to_table('Sed ut perspiciatis unde omnis iste natus error sit voluptatem accusantium doloremque laudantium, totam rem aperiam, eaque ipsa quae ab illo inventore veritatis et quasi architecto beatae vitae dicta sunt explicabo. Nemo enim ipsam voluptatem quia voluptas sit aspernatur aut odit aut fugit, sed quia consequuntur magni dolores eos qui ratione voluptatem sequi nesciunt. Neque porro quisquam est, qui dolorem ipsum quia dolor sit amet, consectetur, adipisci velit, sed quia non numquam eius modi tempora incidunt ut labore et dolore magnam aliquam quaerat voluptatem. Ut enim ad minima veniam, quis nostrum exercitationem ullam corporis suscipit laboriosam, nisi ut aliquid ex ea commodi consequatur Quis autem vel eum iure reprehenderit qui in ea voluptate velit esse quam nihil molestiae consequatur, vel illum qui dolorem eum fugiat quo voluptas nulla pariatur.', '[\s., ]')
    union
    select
      regexp_split_to_table('At vero eos et accusamus et iusto odio dignissimos ducimus qui blanditiis praesentium voluptatum deleniti atque corrupti quos dolores et quas molestias excepturi sint occaecati cupiditate non provident, similique sunt in culpa qui officia deserunt mollitia animi, id est laborum et dolorum fuga. Et harum quidem rerum facilis est et expedita distinctio. Nam libero tempore, cum soluta nobis est eligendi optio cumque nihil impedit quo minus id quod maxime placeat facere possimus, omnis voluptas assumenda est, omnis dolor repellendus. Temporibus autem quibusdam et aut officiis debitis aut rerum necessitatibus saepe eveniet ut et voluptates repudiandae sint et molestiae non recusandae. Itaque earum rerum hic tenetur a sapiente delectus, ut aut reiciendis voluptatibus maiores alias consequatur aut perferendis doloribus asperiores repellat.', '[\s., ]')
  )
  -- Copy data from temporary table to permanent one, with some conditions.
  insert into sandbox.lorem(word)
  select lower(word)
  from w
  where
    word is not null
    and word <> '';
end;
$proc$;

create or replace procedure sandbox.insert_new_user(_email_address text)
language plpgsql
as $proc$
declare
  _new_code char(6) := sandbox.make_numeric_serial();
begin
  insert into sandbox.users(email_address, signin_code)
  values (_email_address, _new_code);
end;
$proc$;

create or replace procedure sandbox.insert_dummy_users(_num_users int)
language plpgsql
as $proc$
begin
  insert into sandbox.users(email_address, signin_code, verification_code_requested_on, verification_code_expiration, verification_code, is_verified, account_updates)
  select
    concat(sandbox.make_lorem(1), sandbox.random(1, 100), '@', sandbox.make_lorem(1), '.com') as email_address,
    sandbox.make_numeric_serial() as signin_code,
    sandbox.random(now() - interval '3 months', now()) as verification_code_requested_on,
    sandbox.random(now(), now() + interval '12 months') as verification_code_expiration,
    substring(MD5(random()::text) from 1 for 8) as verification_code,
    not (sandbox.random(0, 1) = 0) as is_verified,
    sandbox.random(0, 1) as account_updates
  from
  -- Optional table alias, t(x), allows you to theoretically refer to t.x in body of "loop" above if needed.
  generate_series(1, _num_users) as t(x);
end;
$proc$;

create or replace procedure sandbox.signout_user(_user_id int)
language plpgsql
as $proc$
declare
  _new_code char(6) := sandbox.make_numeric_serial();
  _ts_now timestamptz := now();
begin
  update sandbox.users
  set
    signin_code = _new_code,
    signout_ts = _ts_now
  where user_id = _user_id;
end;
$proc$;

create or replace procedure sandbox.insert_problem(_problem_title text, _problem_description text, _problem_tags text[])
language plpgsql
as $proc$
declare
  _ts_now timestamptz := now();
  _ts_year int := extract(year from _ts_now)::int;
  _problem_count int := sandbox.count_problems_in_year(_ts_year) + 1;
begin
  insert into sandbox.problems(per_year_id, date_created, problem_title, problem_description, problem_tags)
  values (_problem_count, _ts_now, _problem_title, _problem_description, _problem_tags);
end;
$proc$;

create or replace procedure sandbox.insert_dummy_problems(_num_problems int)
language plpgsql
as $proc$
declare
  _random_ts timestamptz;
  _ts_year int;
  _problem_title text;
  _problem_title_pretty text;
  _problem_description text;
  _problem_description_pretty text;
  _problem_tags text[];
begin
  for counter in 1.._num_problems loop
    _random_ts := sandbox.random(now() - interval '5 years', now());
    _ts_year := extract(year from _random_ts)::int;
    _problem_title := sandbox.make_lorem (sandbox.random(7, 15));
    -- Capitalize first letter of tile string.
    _problem_title_pretty := overlay(_problem_title placing initcap(substring(_problem_title from 1 for 2)) from 1 for 2);
    _problem_description := sandbox.make_lorem (sandbox.random(25, 50));
    -- Capitalize first letter of description string.
    _problem_description_pretty := overlay(_problem_description placing initcap(substring(_problem_description from 1 for 2)) from 1 for 2);
    _problem_tags := (
      select array_agg(sandbox.make_lorem(1))
      from generate_series(1, sandbox.random(1, 4))
    );
    insert into sandbox.problems(per_year_id, date_created, problem_title, problem_description, problem_tags)
    values (sandbox.count_problems_in_year(_ts_year) + 1, _random_ts, _problem_title_pretty, _problem_description_pretty, _problem_tags);
  end loop;
end;
$proc$;

create or replace procedure sandbox.insert_solution(_problem_id int, _solution_title text, _solution_description text, _solution_tags text[])
language plpgsql
as $proc$
declare
  _ts_now timestamptz := now();
  _solution_count int := sandbox.count_solutions_in_problem(_problem_id) + 1;
begin
  insert into sandbox.solutions(problem_id, per_problem_id, date_created, solution_title, solution_description, solution_tags)
  values (_problem_id, _solution_count, _ts_now, _solution_title, _solution_description, _solution_tags);
end;
$proc$;

create or replace procedure sandbox.insert_dummy_solutions (_max_solutions_per_problem int)
language plpgsql
as $proc$
declare
  _p record;
  _age_limit_ts timestamptz;
  _random_ts timestamptz;
  _solution_title text;
  _solution_title_pretty text;
  _solution_description text;
  _solution_description_pretty text;
  _solution_tags text[];
begin
  for _p in
    select
      problem_id,
      date_created
    from sandbox.problems 
  loop
    -- Prevent solutions from existing before the problem was created.
    _age_limit_ts := _p.date_created;
    for counter in 1..sandbox.random(1, _max_solutions_per_problem) 
    loop
      _random_ts := sandbox.random(_age_limit_ts, now());
      -- Make the next solution newer than the one just entered.
      _age_limit_ts := _random_ts;
      _solution_title := sandbox.make_lorem (sandbox.random(7, 15));
      -- Capitalize first letter of tile string.
      _solution_title_pretty := overlay(_solution_title placing initcap(substring(_solution_title from 1 for 2)) from 1 for 2);
      _solution_description := sandbox.make_lorem (sandbox.random(25, 50));
      -- Capitalize first letter of description string.
      _solution_description_pretty := overlay(_solution_description placing initcap(substring(_solution_description from 1 for 2)) from 1 for 2);
      _solution_tags := (
        select
          array_agg(sandbox.make_lorem (1))
        from
          generate_series(1, sandbox.random(1, 4))
      );
      insert into sandbox.solutions(problem_id, per_problem_id, date_created, solution_title, solution_description, solution_tags)
      values (_p.problem_id, sandbox.count_solutions_in_problem (_p.problem_id) + 1, _random_ts, _solution_title_pretty, _solution_description_pretty, _solution_tags);
    end loop;
  end loop;
end;
$proc$;

create or replace procedure sandbox.insert_problem_link(_problem_id int, _link_title text, _link_url text)
language plpgsql
as $proc$
begin
  -- Omit solution_id intentionally to create null value.
  insert into sandbox.links(problem_id, link_title, link_url)
  values (_problem_id, _link_title, _link_url);
end;
$proc$;

create or replace procedure sandbox.insert_solution_link(_solution_id int, _link_title text, _link_url text)
language plpgsql
as $proc$
begin
  -- Omit problem_id intentionally to create null value.
  insert into sandbox.links(solution_id, link_title, link_url)
  values (_solution_id, _link_title, _link_url);
end;
$proc$;

create or replace procedure sandbox.insert_dummy_links()
language plpgsql
as $proc$
declare
  _p record;
  _s record;
begin
  -- Loop through problems, add 1, 2, or 3 links at random.
  for _p in
    select problem_id
    from sandbox.problems
  loop
    insert into sandbox.links(problem_id, link_title, link_url)
    select
      _p.problem_id as problem_id,
      sandbox.make_lorem(sandbox.random(3, 6)) as link_title, 
      concat('https://', sandbox.make_lorem(1), sandbox.make_lorem(1), '.com', '/', sandbox.make_lorem(1)) as link_url
    from generate_series(1, sandbox.random(1, 3));
  end loop;
  -- Loop through solutions, add 1, 2, or 3 links at random.
  for _s in
    select solution_id
    from sandbox.solutions 
  loop
    insert into sandbox.links(solution_id, link_title, link_url)
    select
      _s.solution_id as solution_id,
      sandbox.make_lorem(sandbox.random(3, 6)) as link_title,
      concat('https://', sandbox.make_lorem(1), '.com', '/', sandbox.make_lorem(1), '/', sandbox.make_lorem(1)) as link_url
    from
      generate_series(1, sandbox.random(1, 3));
  end loop;
end;
$proc$;

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
  -- Grab corresponding problem_id so we can check solution token balance.
  select * into _selected_solution
  from sandbox.solutions
  where solution_id = _solution_id;
  -- Get balance of solution tokens for given user and problem_id.
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
  for _u in
    select user_id, num_d365_tokens
    from sandbox.users 
  loop
    -- Make problem voting plan & solution voting plan arrays.
    _random_balance_floor := _u.num_d365_tokens * sandbox.random(1, 100)::decimal/100;
    _problem_voting_plan := sandbox.make_dummy_problem_voting_plan(_starting_token_balance := _u.num_d365_tokens, _balance_floor := _random_balance_floor);
    _solution_voting_plan := sandbox.make_dummy_solution_voting_plan(_problem_voting_plan := _problem_voting_plan);
    -- Loop over problem voting plan array to cast votes.
    for counter in 1..array_length(_problem_voting_plan, 1)
    loop
      call sandbox.add_problem_vote(_user_id := _u.user_id, _problem_id := _problem_voting_plan[counter][1], _signed_vote := _problem_voting_plan[counter][2]);
    end loop;
    -- Loop over solution voting plan array (if not empty) to cast votes.
    if array_length(_solution_voting_plan, 1) > 0 then
      for counter in 1..array_length(_solution_voting_plan, 1)
      loop
        call sandbox.add_solution_vote(_user_id := _u.user_id, _solution_id := _solution_voting_plan[counter][1], _signed_vote := _solution_voting_plan[counter][2]);
      end loop;
    end if;
  end loop;
end;
$proc$;

create or replace procedure sandbox.log_rank_histories()
language plpgsql
as $proc$
begin
  -- Copy problems from materialized view into log.
  insert into sandbox.problem_rank_history (problem_id, historical_rank, total_votes)
  select * from sandbox.problem_rank;
  -- Copy solutions from materialized view into log.
  insert into sandbox.solution_rank_history (problem_id, solution_id, historical_rank, total_votes)
  select * from sandbox.solution_rank;
end;
$proc$;

create or replace procedure sandbox.delegate(_delegating_user_id int, _recipient_user_id int)
language plpgsql
as $proc$
declare
  _delegating_user_token_balance int;
begin
  -- Check/throw if user is already delegating votes to another user.
  if exists (select 1 from sandbox.delegated_tokens where sandbox.delegated_tokens.delegating_user_id = _delegating_user_id) then
    raise exception sqlstate '90001' using message = 'User is already delegating votes';
  else
    -- Log the delegation.
    insert into sandbox.delegated_tokens (recipient_user_id, delegating_user_id)
    values (_recipient_user_id, _delegating_user_id);
    -- Get token balance. 
    select num_d365_tokens into _delegating_user_token_balance
    from sandbox.users
    where user_id = _delegating_user_id;
    -- Adjust token balance, giver.
    update sandbox.users
    set num_d365_tokens = 0
    where user_id = _delegating_user_id;
    -- Adjust token balance, receiver.
    update sandbox.users
    set num_d365_tokens = num_d365_tokens + _delegating_user_token_balance
    where user_id = _recipient_user_id;
  end if; 
end;
$proc$;

create or replace procedure sandbox.airdrop()
language plpgsql
as $proc$
begin
  -- Use CTE to count "extra" tokens that are owed per delegation count.
  with _total_delegations as (
    select 
      user_id, 
      count(recipient_user_id)
    from sandbox.users
    left join sandbox.delegated_tokens on sandbox.users.user_id = sandbox.delegated_tokens.recipient_user_id
    group by sandbox.users.user_id
  )
  update sandbox.users
  set num_d365_tokens = num_d365_tokens + (1 + _total_delegations.count)
  from _total_delegations
  where 
    sandbox.users.user_id = _total_delegations.user_id and
    -- Do not give tokens to delegating users, as they have already been dropped to recipients.
    not exists (select 1 from sandbox.delegated_tokens where sandbox.delegated_tokens.delegating_user_id = sandbox.users.user_id);
end;
$proc$;

-- *
-- * Sandbox
-- *

call sandbox.insert_lorem_text();

-- Users
call sandbox.insert_dummy_users(500);

call sandbox.insert_new_user(_email_address := 'somebody@email.com');

-- Problems
call sandbox.insert_dummy_problems(100);

call sandbox.insert_problem(_problem_title := 'This is a problem title', _problem_description := 'This is a description of a problem with no length limit?', _problem_tags := '{"single", "word", "tags", "go", "here with spaces?"}');

-- Solutions
call sandbox.insert_dummy_solutions(_max_solutions_per_problem := 3);

call sandbox.insert_solution(_problem_id := 1, _solution_title := 'This is a solution title', _solution_description := 'This is a description of a solution with no length limit?', _solution_tags := '{"single", "word", "tags", "go", "here with spaces?"}');

-- Links
call sandbox.insert_dummy_links();

call sandbox.insert_problem_link(_problem_id := 1, _link_title := 'great article with more info on foobar', _link_url := 'https://google.com');

call sandbox.insert_solution_link(_solution_id := 1, _link_title := 'great article with more info on barfoo', _link_url := 'https://google.com');

-- Votes
call sandbox.insert_dummy_votes();

-- Use "concurrently" option on subsequent refreshes.
refresh materialized view sandbox.problem_rank;
-- select * from sandbox.problem_rank;

-- Use "concurrently" option on subsequent refreshes.
refresh materialized view sandbox.solution_rank;
-- select * from sandbox.solution_rank;


-- Commit or Rollback
commit;