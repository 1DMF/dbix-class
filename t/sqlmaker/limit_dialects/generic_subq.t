use strict;
use warnings;

use Test::More;
use lib qw(t/lib);
use DBICTest;
use DBIC::SqlMakerTest;
use DBIx::Class::SQLMaker::LimitDialects;
my ($ROWS, $TOTAL, $OFFSET) = (
   DBIx::Class::SQLMaker::LimitDialects->__rows_bindtype,
   DBIx::Class::SQLMaker::LimitDialects->__total_bindtype,
   DBIx::Class::SQLMaker::LimitDialects->__offset_bindtype,
);


my $schema = DBICTest->init_schema;

$schema->storage->_sql_maker->renderer_class(
  Moo::Role->create_class_with_roles(qw(
    Data::Query::Renderer::SQL::Naive
    Data::Query::Renderer::SQL::Slice::GenericSubquery
  ))
);

my $rs = $schema->resultset ('BooksInLibrary')->search ({}, {
  '+columns' => [{ owner_name => 'owner.name' }],
  join => 'owner',
  rows => 2,
  order_by => 'me.title',
});

is_same_sql_bind(
  $rs->as_query,
  '(
    SELECT  me.id, me.source, me.owner, me.title, me.price,
            owner__name
      FROM (
        SELECT  me.id, me.source, me.owner, me.title, me.price,
             owner.name AS owner__name
          FROM books me
          JOIN owners owner ON owner.id = me.owner
        WHERE ( source = ? )
      ) me
    WHERE
      (
        SELECT COUNT(*)
          FROM books rownum__emulation
        WHERE rownum__emulation.title < me.title
      ) < ?
    ORDER BY me.title
  )',
  [
    [ { sqlt_datatype => 'varchar', sqlt_size => 100, dbic_colname => 'source' } => 'Library' ],
    [ $ROWS => 2 ],
  ],
);

is_deeply (
  [ $rs->get_column ('title')->all ],
  ['Best Recipe Cookbook', 'Dynamical Systems'],
  'Correct columns selected with rows',
);

$schema->storage->_sql_maker->quote_char ('"');
$schema->storage->_sql_maker->name_sep ('.');

$rs = $schema->resultset ('BooksInLibrary')->search ({}, {
  order_by => { -desc => 'title' },
  '+select' => ['owner.name'],
  '+as' => ['owner.name'],
  join => 'owner',
  rows => 3,
  offset => 1,
});

is_same_sql_bind(
  $rs->as_query,
  '(
    SELECT  "me"."id", "me"."source", "me"."owner", "me"."title", "me"."price",
            "owner__name"
      FROM (
        SELECT  "me"."id", "me"."source", "me"."owner", "me"."title", "me"."price",
                "owner"."name" AS "owner__name", "title" AS "ORDER__BY__001"
          FROM "books" "me"
          JOIN "owners" "owner" ON "owner"."id" = "me"."owner"
        WHERE ( "source" = ? )
      ) "me"
    WHERE
      (
        SELECT COUNT(*)
          FROM "books" "rownum__emulation"
        WHERE "rownum__emulation"."title" > "ORDER__BY__001"
      ) BETWEEN ? AND ?
    ORDER BY "ORDER__BY__001" DESC
  )',
  [
    [ { sqlt_datatype => 'varchar', sqlt_size => 100, dbic_colname => 'source' } => 'Library' ],
    [ $OFFSET => 1 ],
    [ $TOTAL => 3 ],
  ],
);

is_deeply (
  [ $rs->get_column ('title')->all ],
  [ 'Dynamical Systems', 'Best Recipe Cookbook' ],
  'Correct columns selected with rows',
);

$rs = $schema->resultset ('BooksInLibrary')->search ({}, {
  order_by => 'title',
  'select' => ['owner.name'],
  'as' => ['owner_name'],
  join => 'owner',
  offset => 1,
});

is_same_sql_bind(
  $rs->as_query,
  '(
    SELECT "owner"."name"
      FROM (
        SELECT "owner"."name", "title" AS "ORDER__BY__001"
          FROM "books" "me"
          JOIN "owners" "owner" ON "owner"."id" = "me"."owner"
        WHERE ( "source" = ? )
      ) "owner"
    WHERE
      (
        SELECT COUNT(*)
          FROM "books" "rownum__emulation"
        WHERE "rownum__emulation"."title" < "ORDER__BY__001"
      ) BETWEEN ? AND ?
    ORDER BY "ORDER__BY__001"
  )',
  [
    [ { sqlt_datatype => 'varchar', sqlt_size => 100, dbic_colname => 'source' } => 'Library' ],
    [ $OFFSET => 1 ],
    [ $TOTAL => 2147483647 ],
  ],
);

is_deeply (
  [ $rs->get_column ('owner_name')->all ],
  [ ('Newton') x 2 ],
  'Correct columns selected with rows',
);

{
  $rs = $schema->resultset('Artist')->search({}, {
    columns => 'artistid',
    offset => 1,
    order_by => 'artistid',
  });
  local $rs->result_source->{name} = "weird \n newline/multi \t \t space containing \n table";

  like (
    ${$rs->as_query}->[0],
    qr| weird \s \n \s newline/multi \s \t \s \t \s space \s containing \s \n \s table|x,
    'Newlines/spaces preserved in final sql',
  );
}

# this is a nonsensical order_by, we are just making sure the bind-transport is correct
# (not that it'll be useful anywhere in the near future)
my $attr = {};
my $rs_selectas_rel = $schema->resultset('BooksInLibrary')->search(undef, {
  columns => 'me.id',
  offset => 3,
  rows => 4,
  '+columns' => { bar => { '' => \['? * ?', [ $attr => 11 ], [ $attr => 12 ]], -as => 'bar' }, baz => { '' => \[ '?', [ $attr => 13 ]], -as => 'baz' } },
  order_by => [ 'id', \['? / ?', [ $attr => 1 ], [ $attr => 2 ]], \[ '?', [ $attr => 3 ]] ],
  having => \[ '?', [ $attr => 21 ] ],
});

is_same_sql_bind(
  $rs_selectas_rel->as_query,
  '(
    SELECT "me"."id", "bar", "baz"
      FROM (
        SELECT "me"."id", ? * ? AS "bar", ? AS "baz", "id" AS "ORDER__BY__001", ? / ? AS "ORDER__BY__002", ? AS "ORDER__BY__003"
          FROM "books" "me"
        WHERE ( "source" = ? )
        HAVING ?
      ) "me"
    WHERE ( SELECT COUNT(*) FROM "books" "rownum__emulation" WHERE "rownum__emulation"."id" < "ORDER__BY__001" ) BETWEEN ? AND ?
    ORDER BY "ORDER__BY__001", "ORDER__BY__002", "ORDER__BY__003"
  )',
  [
    [ $attr => 11 ], [ $attr => 12 ], [ $attr => 13 ],
    [ $attr => 1 ], [ $attr => 2 ], [ $attr => 3 ],
    [ { sqlt_datatype => 'varchar', sqlt_size => 100, dbic_colname => 'source' } => 'Library' ],
    [ $attr => 21 ],
    [ {%$OFFSET} => 3 ],
    [ {%$TOTAL} => 6 ],
  ],
  'Pagination with sub-query in ORDER BY works'
);

done_testing;
