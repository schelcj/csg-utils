package CSG::Storage::SlotFS::Command::update_project;

use CSG::Storage::SlotFS -command;

use CSG::Storage::Slots::DB;

sub opt_spec {
  return (
    ['project|p=s', 'Project to modifiy', {required => 1}],
    ['name=s',      'New project name',   {requried => 1}]
  );
}

sub validate_args {
  my ($self, $opts, $args) = @_;

  my $schema = CSG::Storage::Slots::DB->new();
  my $project = $schema->resultset('Project')->find({name => $opts->{project}});
  unless ($project) {
    $self->usage_error('Project does not exist');
  }

  if ($schema->resultset('Project')->find({name => $opts->{name}})) {
    $self->usage_error('New project name already exists');
  }


}

sub execute {
  my ($self, $opts, $args) = @_;

  my $schema = CSG::Storage::Slots::DB->new();
  my $project = $schema->resultset('Project')->find({name => $opts->{project}});
  $project->update({name => $opts->{name}});
}

1;

__END__

=head1

CSG::Storage::SlotFS::Command::update_project - Update a projects details
