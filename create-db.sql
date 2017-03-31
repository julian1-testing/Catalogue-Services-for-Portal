
-- psql -h postgres.localnet -U admin -d postgres -f db.sql

drop database if exists harvest; 
drop role if exists harvest; 

create role harvest password 'harvest' login; 
create database harvest owner harvest; 

\c harvest


begin;


--------

-- facet search stuff?


create table scheme (

  id serial   primary key not null,
  url         text not null unique,
  title       text not null
);
alter table scheme owner to harvest;


create table concept (

  id serial   primary key not null,
  url         text not null unique,
  label       text not null
);
alter table concept owner to harvest;


create table narrower (

  id serial   primary key not null,
  concept_id  integer references concept(id), 
  narrower_id integer references concept(id)
);
alter table narrower owner to harvest;

-- TODO uniqueness constraint on the combination  that link things,


create table narrow_match (

  id serial   primary key not null,
  concept_id  integer references concept(id), 
  narrower_id integer references concept(id)
);
alter table narrow_match owner to harvest;


create table in_scheme (

  id serial   primary key not null,
  concept_id  integer references concept(id), 
  scheme_id   integer references scheme(id)
);
alter table in_scheme owner to harvest;



--------------

-- want a catalog table as well - dependening on harvest source?
-- actually may not even need...

create table record (

  id          serial primary key not null,
  uuid        text not null unique,
  title       text not null
);

alter table record owner to harvest;

-- TODO add uniqueness constraints - dd

create table resource (

  id serial   primary key not null,
  record_id  integer references record(id), 

  protocol    text not null,
  linkage     text not null,
  description text 
);

alter table resource owner to harvest;


-- its actually not facet - but the facet index...

create table facet (

  id serial   primary key not null,

  record_id  integer references record(id), 
  concept_id  integer references concept(id)
);

alter table facet owner to harvest;

commit;