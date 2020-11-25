-- Test queries on RDS instance.
begin;

create schema sandbox;

create table sandbox.accounts (
  id int generated always as identity,
  name text not null,
  balance DEC (15, 2) not null,
  primary key (id)
);

insert into sandbox.accounts (name, balance)
  values ('Bob', 10000), ('Alice', 10000), ('John', 20000), ('Jane', 30000), ('Susan', 40000), ('Steve', 50000)
returning
  *;

commit;

