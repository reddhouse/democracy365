begin;

create table if not exists accounts (
  id int generated always as identity,
  name text not null,
  balance DEC (15, 2) not null,
  primary key (id)
);

insert into accounts (name, balance)
  values ('Bob', 10000), ('Alice', 10000), ('Alice2', 20000), ('Alice3', 30000), ('Alice4', 40000), ('Alice5', 50000)
returning
  *;

select
  id,
  balance
from
  accounts;

update
  accounts
set
  balance = balance + 1000
where
  id = 3;

-- View changes from update
select
  id,
  name,
  balance
from
  accounts
order by
  id asc;

rollback;

-- *
-- *
-- Example of surrogate key and strong 1NF guarantee with "unique" keyword, where unique is used as table constraint, rather than the more common notation of column constraint(s).
-- create table sandboxpk.article (
--   id bigserial primary key,
--   category integer not null references sandbox.category (id),
--   pubdate timestamptz not null,
--   title text not null,
--   content text,
--   -- A new article can have the same title and/or pubdate as another article, but not within the same category.
--   unique (category, pubdate, title)
-- );
