package CSG::Storage::SlotCtl::Command::add_pool;

use CSG::Storage::SlotCtl -command;
use CSG::Base qw(file);
use CSG::Storage::Slots::DB;

use Number::Bytes::Human qw(parse_bytes);

sub opt_spec {
  return (
    ['name|n=s',     'Descriptive name for the pool',                                       {required => 1}],
    ['hostname|w=s', 'Hostname that the pool resides on (for nfs based pools)',             {required => 1}],
    ['path|t=s',     'Path where slots will be stored',                                     {required => 1}],
    ['size|s=s',     'Total space available for slots in human readable form (i.e. 400TB)', {required => 1}],
  );
}

sub validate_args {
  my ($self, $opts, $args) = @_;

  my $schema = CSG::Storage::Slots::DB->new();
  unless ($schema->resultset('Project')->find({name => $self->app->global_options->{project}})) {
    $self->exit_with_error('project does not exist');
  }

  if ($schema->resultset('Pool')->find({name => $opts->{name}})) {
    $self->exit_with_error('pool already exists');
  }

  my $prefix = $self->app->global_options->{prefix};
  if ($opts->{path} =~ /^$prefix/) {
    $self->exit_with_error("Prefix path, $prefix, should not be included in pool path, $opts->{path}");
  }
}

sub execute {
  my ($self, $opts, $args) = @_;

  my $schema  = CSG::Storage::Slots::DB->new();
  my $type    = $schema->resultset('Type')->find_or_create({name => 'nfs'});
  my $project = $schema->resultset('Project')->find({name => $self->app->global_options->{project}});
  my $pool    = $project->add_to_pools(
    {
      name       => $opts->{name},
      hostname   => $opts->{hostname},
      path       => $opts->{path},
      size_total => parse_bytes($opts->size),
      type_id    => $type->id,
    }
  );
}

1;

__END__

=head1

CSG::Storage::SlotCtl::Command::add_pool - Add a new pool to server slots
