create table users
(
    username           text     primary key
  , password           text
  , last_authenticated text
  , auth_key           text
  , port               integer
  , display_number     integer
);
