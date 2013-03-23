package DBIx::Class::SQLMaker;

use strict;
use warnings;

=head1 NAME

DBIx::Class::SQLMaker - An SQL::Abstract-based SQL maker class

=head1 DESCRIPTION

This module is a subclass of L<SQL::Abstract> and includes a number of
DBIC-specific workarounds, not yet suitable for inclusion into the
L<SQL::Abstract> core. It also provides all (and more than) the functionality
of L<SQL::Abstract::Limit>, see L<DBIx::Class::SQLMaker::LimitDialects> for
more info.

Currently the enhancements to L<SQL::Abstract> are:

=over

=item * Support for C<JOIN> statements (via extended C<table/from> support)

=item * Support of functions in C<SELECT> lists

=item * C<GROUP BY>/C<HAVING> support (via extensions to the order_by parameter)

=item * Support of C<...FOR UPDATE> type of select statement modifiers

=item * The L</-ident> operator

=item * The L</-value> operator

=back

=cut

use base qw/
  SQL::Abstract
  DBIx::Class::SQLMaker::LimitDialects
/;
use mro 'c3';

use Module::Runtime qw(use_module);
use Sub::Name 'subname';
use DBIx::Class::Carp;
use DBIx::Class::Exception;
use Moo;
use namespace::clean;

has limit_dialect => (
  is => 'rw', default => sub { 'LimitOffset' },
  trigger => sub { shift->clear_renderer_class }
);

around _build_renderer_roles => sub {
  my ($orig, $self) = (shift, shift);
  return (
    $self->$orig(@_),
    'Data::Query::Renderer::SQL::Slice::'.$self->limit_dialect
  );
};

# for when I need a normalized l/r pair
sub _quote_chars {
  map
    { defined $_ ? $_ : '' }
    ( ref $_[0]->{quote_char} ? (@{$_[0]->{quote_char}}) : ( ($_[0]->{quote_char}) x 2 ) )
  ;
}

sub _build_converter_class {
  Module::Runtime::use_module('DBIx::Class::SQLMaker::Converter')
}

# FIXME when we bring in the storage weaklink, check its schema
# weaklink and channel through $schema->throw_exception
sub throw_exception { DBIx::Class::Exception->throw($_[1]) }

BEGIN {
  # reinstall the belch()/puke() functions of SQL::Abstract with custom versions
  # that use DBIx::Class::Carp/DBIx::Class::Exception instead of plain Carp
  no warnings qw/redefine/;

  *SQL::Abstract::belch = subname 'SQL::Abstract::belch' => sub (@) {
    my($func) = (caller(1))[3];
    carp "[$func] Warning: ", @_;
  };

  *SQL::Abstract::puke = subname 'SQL::Abstract::puke' => sub (@) {
    my($func) = (caller(1))[3];
    __PACKAGE__->throw_exception("[$func] Fatal: " . join ('',  @_));
  };

  # Current SQLA pollutes its namespace - clean for the time being
  namespace::clean->clean_subroutines(qw/SQL::Abstract carp croak confess/);
}

# the "oh noes offset/top without limit" constant
# limited to 31 bits for sanity (and consistency,
# since it may be handed to the like of sprintf %u)
#
# Also *some* builds of SQLite fail the test
#   some_column BETWEEN ? AND ?: 1, 4294967295
# with the proper integer bind attrs
#
# Implemented as a method, since ::Storage::DBI also
# refers to it (i.e. for the case of software_limit or
# as the value to abuse with MSSQL ordered subqueries)
sub __max_int () { 0x7FFFFFFF };

# poor man's de-qualifier
sub _quote {
  $_[0]->next::method( ( $_[0]{_dequalify_idents} and ! ref $_[1] )
    ? $_[1] =~ / ([^\.]+) $ /x
    : $_[1]
  );
}

sub _where_op_NEST {
  carp_unique ("-nest in search conditions is deprecated, you most probably wanted:\n"
      .q|{..., -and => [ \%cond0, \@cond1, \'cond2', \[ 'cond3', [ col => bind ] ], etc. ], ... }|
  );

  shift->next::method(@_);
}

# Handle limit-dialect selection
sub select {
  my ($self, $table, $fields, $where, $rs_attrs, $limit, $offset) = @_;

  if (defined $offset) {
    $self->throw_exception('A supplied offset must be a non-negative integer')
      if ( $offset =~ /\D/ or $offset < 0 );
  }
  $offset ||= 0;

  if (defined $limit) {
    $self->throw_exception('A supplied limit must be a positive integer')
      if ( $limit =~ /\D/ or $limit <= 0 );
  }
  elsif ($offset) {
    $limit = $self->__max_int;
  }

  my %final_attrs = (%{$rs_attrs||{}}, limit => $limit, offset => $offset);

  my %slice_stability = $self->renderer->slice_stability;

  if (my $stability = $slice_stability{$offset ? 'offset' : 'limit'}) {
    my $source = $rs_attrs->{_rsroot_rsrc};
    unless (
      $final_attrs{order_is_stable}
      = $final_attrs{preserve_order}
      = $source->schema->storage
               ->_order_by_is_stable(
                   @final_attrs{qw(from order_by where)}
                 )
    ) {
      if ($stability eq 'requires') {
        if ($self->converter->_order_by_to_dq($final_attrs{order_by})) {
          $self->throw_exception(
            $self->limit_dialect.' limit/offset implementation requires a stable order for offset'
          );
        }
        if (my $ident_cols = $source->_identifying_column_set) {
          $final_attrs{order_by} = [
            map "$final_attrs{alias}.$_", @$ident_cols
          ];
          $final_attrs{order_is_stable} = 1;
        } else {
          $self->throw_exception(sprintf(
            'Unable to auto-construct stable order criteria for "skimming type" 
limit '
          . "dialect based on source '%s'", $source->name) );
        }
      }
    }

  }

  my %slice_subquery = $self->renderer->slice_subquery;

  if (my $subquery = $slice_subquery{$offset ? 'offset' : 'limit'}) {
    $fields = [ map {
      my $f = $fields->[$_];
      if (ref $f) {
        $f = { '' => $f } unless ref($f) eq 'HASH';
        $f->{-as} ||= $final_attrs{as}[$_];
      }
      $f;
    } 0 .. $#$fields ];
  }

  my ($sql, @bind) = $self->next::method ($table, $fields, $where, $final_attrs{order_by}, \%final_attrs );

  $sql .= $self->_lock_select ($rs_attrs->{for})
    if $rs_attrs->{for};

  return wantarray ? ($sql, @bind) : $sql;
}

sub _assemble_binds {
  my $self = shift;
  return map { @{ (delete $self->{"${_}_bind"}) || [] } } (qw/pre_select select from where group having order limit/);
}

my $for_syntax = {
  update => 'FOR UPDATE',
  shared => 'FOR SHARE',
};
sub _lock_select {
  my ($self, $type) = @_;
  my $sql = $for_syntax->{$type} || $self->throw_exception( "Unknown SELECT .. FOR type '$type' requested" );
  return " $sql";
}

sub _recurse_from {
  scalar shift->_render_sqla(table => \@_);
}

1;

=head1 OPERATORS

=head2 -ident

Used to explicitly specify an SQL identifier. Takes a plain string as value
which is then invariably treated as a column name (and is being properly
quoted if quoting has been requested). Most useful for comparison of two
columns:

    my %where = (
        priority => { '<', 2 },
        requestor => { -ident => 'submitter' }
    );

which results in:

    $stmt = 'WHERE "priority" < ? AND "requestor" = "submitter"';
    @bind = ('2');

=head2 -value

The -value operator signals that the argument to the right is a raw bind value.
It will be passed straight to DBI, without invoking any of the SQL::Abstract
condition-parsing logic. This allows you to, for example, pass an array as a
column value for databases that support array datatypes, e.g.:

    my %where = (
        array => { -value => [1, 2, 3] }
    );

which results in:

    $stmt = 'WHERE array = ?';
    @bind = ([1, 2, 3]);

=head1 AUTHORS

See L<DBIx::Class/CONTRIBUTORS>.

=head1 LICENSE

You may distribute this code under the same terms as Perl itself.

=cut
