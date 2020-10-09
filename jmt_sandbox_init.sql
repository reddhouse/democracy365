begin;

create schema sandbox;

-- *
-- * Tables
-- *

create table sandbox.lorem (
  word text
);

create table sandbox.users (
  user_id int generated always as identity primary key,
  -- Default one token for each day that has elapsed since "go-live" date.
  num_d365_tokens int default (current_date - date '2020-01-01'),
  email_address citext not null unique,
  non_verified_mailing_address text,
  verified_mailing_address text,
  verification_code_requested_on timestamptz,
  verification_code_expiration timestamptz,
  verification_code text,
  is_verified boolean,
  no_sql jsonb,
  account_updates smallint
);

create table sandbox.problems (
  problem_id int generated always as identity primary key,
  per_year_id int,
  date_created timestamptz,
  problem_title text,
  problem_description text,
  problem_tags text[]
);

create table sandbox.solutions (
  solution_id int generated always as identity primary key,
  problem_id int references sandbox.problems (problem_id),
  per_problem_id int,
  date_created timestamptz,
  solution_title text,
  solution_description text,
  solution_tags text[],
  no_sql jsonb
);

create table sandbox.links (
  link_id int generated always as identity primary key,
  problem_id int references sandbox.problems (problem_id),
  solution_id int references sandbox.solutions (solution_id),
  link_title text,
  link_url text
);

-- *
-- * Functions
-- *

create or replace function sandbox.random(a int, b int)
-- Returns a random number within provided range.
  returns int volatile
  language sql
  as $func$
  select
    a + ((b - a) * random())::int;

$func$;

create or replace function sandbox.random(a timestamptz, b timestamptz)
-- Overload sandbox.random
-- Returns a timestamp within provided range.
  returns timestamptz volatile
  language sql
  as $func$
  select
    a + sandbox.random(0, extract(epoch from (b - a))::int) * interval '1 sec';

$func$;

create or replace function sandbox.make_lorem (len int)
  returns text volatile
  language sql
  as $func$
  with words (
    w
) as (
    select
      word
    from
      sandbox.lorem
    order by
      random()
    limit len
)
select
  string_agg(w, ' ')
from
  words;

$func$;

create or replace function sandbox.count_problems_in_year (year int, out num_problems int)
language plpgsql
as $func$
begin
  select
    count(*) into num_problems
  from
    sandbox.problems
  where
    extract(year from date_created)::int = year;
end
$func$;

create or replace function sandbox.count_solutions_in_problem (p_id int, out num_solutions int)
language plpgsql
as $func$
begin
  select
    count(*) into num_solutions
  from
    sandbox.solutions
  where
    problem_id = p_id;
end
$func$;

-- *
-- * Procedures
-- *

create or replace procedure sandbox.insert_problem (problem_title text, problem_description text, problem_tags text[])
language plpgsql
as $proc$
declare
  ts_now timestamptz := now();
  ts_year int := extract(year from ts_now)::int;
  problem_count int := sandbox.count_problems_in_year (ts_year) + 1;
begin
  insert into sandbox.problems (per_year_id, date_created, problem_title, problem_description, problem_tags)
    values (problem_count, ts_now, problem_title, problem_description, problem_tags);
end;
$proc$;

create or replace procedure sandbox.insert_dummy_problems (num_problems int)
language plpgsql
as $proc$
declare
  random_ts timestamptz;
  ts_year int;
  problem_title text;
  problem_title_pretty text;
  problem_description text;
  problem_description_pretty text;
  problem_tags text[];
begin
  for counter in 1..num_problems loop
    random_ts := sandbox.random(now() - interval '5 years', now());
    ts_year := extract(year from random_ts)::int;
    problem_title := sandbox.make_lorem (sandbox.random(7, 15));
    -- Capitalize first letter of tile string.
    problem_title_pretty := overlay(problem_title placing initcap(substring(problem_title from 1 for 2))
      from 1 for 2);
    problem_description := sandbox.make_lorem (sandbox.random(25, 50));
    -- Capitalize first letter of description string.
    problem_description_pretty := overlay(problem_description placing initcap(substring(problem_description from 1 for 2))
      from 1 for 2);
    problem_tags := (
      select
        array_agg(sandbox.make_lorem (1))
      from
        generate_series(1, sandbox.random(1, 4)));
    insert into sandbox.problems (per_year_id, date_created, problem_title, problem_description, problem_tags)
      values (sandbox.count_problems_in_year (ts_year) + 1, random_ts, problem_title_pretty, problem_description_pretty, problem_tags);
  end loop;
end;
$proc$;

create or replace procedure sandbox.insert_solution (problem_id int, solution_title text, solution_description text, solution_tags text[])
language plpgsql
as $proc$
declare
  ts_now timestamptz := now();
  solution_count int := sandbox.count_solutions_in_problem (problem_id) + 1;
begin
  insert into sandbox.solutions (problem_id, per_problem_id, date_created, solution_title, solution_description, solution_tags)
    values (problem_id, solution_count, ts_now, solution_title, solution_description, solution_tags);
end;
$proc$;

create or replace procedure sandbox.insert_dummy_solutions (max_solutions int)
language plpgsql
as $proc$
declare
  p record;
  age_limit_ts timestamptz;
  random_ts timestamptz;
  solution_title text;
  solution_title_pretty text;
  solution_description text;
  solution_description_pretty text;
  solution_tags text[];
begin
  for p in
  select
    problem_id,
    date_created
  from
    sandbox.problems loop
      -- Prevent solutions from existing before the problem was created.
      age_limit_ts := p.date_created;
      for counter in 1..sandbox.random(1, max_solutions)
      loop
        random_ts := sandbox.random(age_limit_ts, now());
        -- Make the next solution newer than the one just entered.
        age_limit_ts := random_ts;
        solution_title := sandbox.make_lorem (sandbox.random(7, 15));
        -- Capitalize first letter of tile string.
        solution_title_pretty := overlay(solution_title placing initcap(substring(solution_title from 1 for 2))
          from 1 for 2);
        solution_description := sandbox.make_lorem (sandbox.random(25, 50));
        -- Capitalize first letter of description string.
        solution_description_pretty := overlay(solution_description placing initcap(substring(solution_description from 1 for 2))
          from 1 for 2);
        solution_tags := (
          select
            array_agg(sandbox.make_lorem (1))
          from
            generate_series(1, sandbox.random(1, 4)));
        insert into sandbox.solutions (problem_id, per_problem_id, date_created, solution_title, solution_description, solution_tags)
          values (p.problem_id, sandbox.count_solutions_in_problem (p.problem_id) + 1, random_ts, solution_title_pretty, solution_description_pretty, solution_tags);
      end loop;
    end loop;
end;
$proc$;

create or replace procedure sandbox.insert_problem_link (problem_id int, link_title text, link_url text)
language plpgsql
as $proc$
begin
  -- Omit solution_id intentionally to create null value.
  insert into sandbox.links (problem_id, link_title, link_url)
    values (problem_id, link_title, link_url);
end;
$proc$;

create or replace procedure sandbox.insert_solution_link (solution_id int, link_title text, link_url text)
language plpgsql
as $proc$
begin
  -- Omit problem_id intentionally to create null value.
  insert into sandbox.links (solution_id, link_title, link_url)
    values (solution_id, link_title, link_url);
end;
$proc$;

create or replace procedure sandbox.insert_dummy_links ()
language plpgsql
as $proc$
declare
  p record;
  s record;
begin
  -- Loop through problems, add 1, 2, or 3 links at random.
  for p in
  select
    problem_id
  from
    sandbox.problems loop
      insert into sandbox.links (problem_id, link_title, link_url)
      select
        p.problem_id as problem_id,
        sandbox.make_lorem (sandbox.random(3, 6)) as link_title,
      concat('https://', sandbox.make_lorem (1), sandbox.make_lorem (1), '.com', '/', sandbox.make_lorem (1)) as link_url
from
  generate_series(1, sandbox.random(1, 3));
    end loop;
  -- Loop through solutions, add 1, 2, or 3 links at random.
  for s in
  select
    solution_id
  from
    sandbox.solutions loop
      insert into sandbox.links (solution_id, link_title, link_url)
      select
        s.solution_id as solution_id,
        sandbox.make_lorem (sandbox.random(3, 6)) as link_title,
      concat('https://', sandbox.make_lorem (1), '.com', '/', sandbox.make_lorem (1), '/', sandbox.make_lorem (1)) as link_url
from
  generate_series(1, sandbox.random(1, 3));
    end loop;
end;
$proc$;

-- *
-- * Data
-- *

with w (
  word
  -- Temporary table 'w', with 'word' column.
) as (
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
insert into sandbox.lorem (word)
select
  lower(word)
from
  w
where
  word is not null
  and word <> '';

insert into sandbox.users (email_address, verification_code_requested_on, verification_code_expiration, verification_code, is_verified, account_updates)
select
  concat(sandbox.make_lorem (1), '@', sandbox.make_lorem (1), '.com') as email_address,
  sandbox.random(now() - interval '3 months', now()) as verification_code_requested_on,
  sandbox.random(now(), now() + interval '12 months') as verification_code_expiration,
  substring(MD5(random()::text)
  from 1 for 8) as verification_code,
  not (sandbox.random(0, 1) = 0) as is_verified,
  sandbox.random(0, 1) as account_updates
from
-- Optional table alias t(x) could theoretically refer to t.x in body of "loop" above if needed.
generate_series(1, 5) as t (x);

-- *
-- * Output
-- *

call sandbox.insert_dummy_problems (4);

-- Non-dummy call to insert single problem into problems table.
call sandbox.insert_problem ('This is a problem title', 'This is a description of a problem with no length limit?', '{"single", "word", "tags", "go", "here with spaces?"}');

call sandbox.insert_dummy_solutions (3);

-- Non-dummy call to insert single solution into solutions table.
call sandbox.insert_solution (problem_id := 1, solution_title := 'This is a solution title', solution_description := 'This is a description of a solution with no length limit?', solution_tags := '{"single", "word", "tags", "go", "here with spaces?"}');

call sandbox.insert_dummy_links ();

-- Non-dummy call to insert single problem link into links table.
call sandbox.insert_problem_link (problem_id := 1, link_title := 'great article with more info on foobar', link_url := 'https://google.com');

-- Non-dummy call to insert single solution link into links table.
call sandbox.insert_solution_link (solution_id := 1, link_title := 'great article with more info on barfoo', link_url := 'https://google.com');

select
  *
from
  sandbox.users;

select
  *
from
  sandbox.problems;

select
  *
from
  sandbox.solutions;

select
  *
from
  sandbox.links;

rollback;

