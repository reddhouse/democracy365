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
  forced_reclaim_in_progress boolean default 'false',
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
    concat(sandbox.make_lorem(1), '@', sandbox.make_lorem(1), '.com') as email_address,
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

-- *
-- * Sandbox
-- *

call sandbox.insert_lorem_text();

-- Users
call sandbox.insert_dummy_users(5);

call sandbox.insert_new_user(_email_address := 'somebody@email.com');

call sandbox.signout_user(6);

-- Problems
call sandbox.insert_dummy_problems(4);

call sandbox.insert_problem(_problem_title := 'This is a problem title', _problem_description := 'This is a description of a problem with no length limit?', _problem_tags := '{"single", "word", "tags", "go", "here with spaces?"}');

-- Solutions
call sandbox.insert_dummy_solutions(_max_solutions_per_problem := 3);

call sandbox.insert_solution(_problem_id := 1, _solution_title := 'This is a solution title', _solution_description := 'This is a description of a solution with no length limit?', _solution_tags := '{"single", "word", "tags", "go", "here with spaces?"}');

-- Links
call sandbox.insert_dummy_links();

call sandbox.insert_problem_link(_problem_id := 1, _link_title := 'great article with more info on foobar', _link_url := 'https://google.com');

call sandbox.insert_solution_link(_solution_id := 1, _link_title := 'great article with more info on barfoo', _link_url := 'https://google.com');

-- Display
select *
from sandbox.users;

select *
from sandbox.problems;

select *
from sandbox.solutions;

select *
from sandbox.links;

-- Commit or Rollback
rollback;

