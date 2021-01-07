-- Test queries on RDS instance.
begin;

create schema sandbox;

create or replace function sandbox.numeric_serial()
returns char(6)
language plpgsql
as $func$
declare
  _serial char(6);
  _i int;
  _chars char(10) = '0123456789';
begin
  _serial = '';
  for _i in 1..6 loop
    _serial = _serial || substr(_chars, int4(floor(random() * length(_chars))) + 1, 1);
  end loop;
return lower(_serial);
end
$func$;

create table sandbox.users (
  user_id int generated always as identity,
  email_address citext not null unique,
  signin_code char(6) default sandbox.numeric_serial () unique,
  signout_ts timestamptz default now(),
  primary key (user_id)
);

insert into sandbox.users (email_address)
values ('bob@email.com'), ('alice@email.com'), ('john@email.com'), ('jane@email.com'), ('susan@email.com'), ('steve@email.com')
returning *;

commit;

