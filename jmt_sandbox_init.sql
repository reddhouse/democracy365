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

-- *
-- * Functions
-- *

create or replace function sandbox.random(a int, b int)
-- Returns a random number within provided range
  returns int volatile
  language sql
  as $$
  select
    a + ((b - a) * random())::int;

$$;

create or replace function sandbox.random(a timestamptz, b timestamptz)
-- Overload sandbox.random
-- Returns a timestamp within provided range
  returns timestamptz volatile
  language sql
  as $$
  select
    a + sandbox.random(0, extract(epoch from (b - a))::int) * interval '1 sec';

$$;

create or replace function sandbox.make_lorem (len int)
  returns text volatile
  language sql
  as $$
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

$$;

create or replace function sandbox.count_in_year (_tbl regclass, comparison_year int, out result int)
language plpgsql
as $func$
begin
  execute format('
  select count(*)
  from %s
  where extract(year from date_created)::int = %s', _tbl, comparison_year) into result;
end
$func$;

-- *
-- * Procedures
-- *

create or replace procedure sandbox.insert_problem (title text, summary text, tags text[])
language plpgsql
as $proc$
declare
  ts timestamptz := now();
  ts_year int := extract(year from ts)::int;
  year_count int := sandbox.count_in_year ('sandbox.problems', ts_year) + 1;
begin
  insert into sandbox.problems (per_year_id, date_created, problem_title, problem_description, problem_tags)
    values (year_count, ts, title, summary, tags);
end;
$proc$;

create or replace procedure sandbox.insert_dummy_problems (iterations int)
language plpgsql
as $proc$
declare
  random_ts timestamptz;
  ts_year int;
  tags text[];
begin
  for counter in 1..iterations loop
    random_ts := sandbox.random(now() - interval '5 years', now());
    ts_year := extract(year from random_ts)::int;
    tags := (
      select
        array_agg(sandbox.make_lorem (1))
      from
        generate_series(0, sandbox.random(1, 4)));
    insert into sandbox.problems (per_year_id, date_created, problem_tags)
      values ((sandbox.count_in_year ('sandbox.problems', ts_year)) + 1, random_ts, tags);
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
    regexp_split_to_table('Sed ut perspiciatis unde omnis iste natus error sit voluptatem accusantium doloremque laudantium, totam rem aperiam, eaque ipsa quae ab illo inventore veritatis et quasi architecto beatae vitae dicta sunt explicabo. Nemo enim ipsam voluptatem quia voluptas sit aspernatur aut odit aut fugit, sed quia consequuntur magni dolores eos qui ratione voluptatem sequi nesciunt. Neque porro quisquam est, qui dolorem ipsum quia dolor sit amet, consectetur, adipisci velit, sed quia non numquam eius modi tempora incidunt ut labore et dolore magnam aliquam quaerat voluptatem. Ut enim ad minima veniam, quis nostrum exercitationem ullam corporis suscipit laboriosam, nisi ut aliquid ex ea commodi consequatur? Quis autem vel eum iure reprehenderit qui in ea voluptate velit esse quam nihil molestiae consequatur, vel illum qui dolorem eum fugiat quo voluptas nulla pariatur?', '[\s., ]')
  union
  select
    regexp_split_to_table('At vero eos et accusamus et iusto odio dignissimos ducimus qui blanditiis praesentium voluptatum deleniti atque corrupti quos dolores et quas molestias excepturi sint occaecati cupiditate non provident, similique sunt in culpa qui officia deserunt mollitia animi, id est laborum et dolorum fuga. Et harum quidem rerum facilis est et expedita distinctio. Nam libero tempore, cum soluta nobis est eligendi optio cumque nihil impedit quo minus id quod maxime placeat facere possimus, omnis voluptas assumenda est, omnis dolor repellendus. Temporibus autem quibusdam et aut officiis debitis aut rerum necessitatibus saepe eveniet ut et voluptates repudiandae sint et molestiae non recusandae. Itaque earum rerum hic tenetur a sapiente delectus, ut aut reiciendis voluptatibus maiores alias consequatur aut perferendis doloribus asperiores repellat.', '[\s., ]')
)
-- Copy data from temporary table to permanent one, with some conditions.
insert into sandbox.lorem (word)
select
  word
from
  w
where
  word is not null
  and word <> '';

insert into sandbox.users (email_address, verification_code_requested_on, verification_code_expiration, verification_code, is_verified)
select
  concat(sandbox.make_lorem (1), '@', sandbox.make_lorem (1), '.com') as email_address,
  sandbox.random(now() - interval '3 months', now()) as verification_code_requested_on,
  sandbox.random(now(), now() + interval '12 months') as verification_code_expiration,
  substring(MD5(random()::text)
  from 1 for 8) as verification_code,
  not (sandbox.random(0, 1) = 0) as is_verified
from
  generate_series(1, 3) as t (x);

-- *
-- * Output
-- *

call sandbox.insert_dummy_problems (4);

call sandbox.insert_problem ('This is a problem title', 'This is a description of a problem with no length limit.', '{"single", "word", "tags", "go", "here and here?"}');

select
  *
from
  sandbox.users;

select
  *
from
  sandbox.problems;

rollback;

