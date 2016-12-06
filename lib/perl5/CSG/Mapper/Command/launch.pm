## no critic (NamingConventions::Capitalization, Subroutines::RequireFinalReturn)
package CSG::Mapper::Command::launch;

use CSG::Mapper -command;
use CSG::Base qw(file templates www);
use CSG::Constants qw(:basic :mapping);
use CSG::Mapper::Config;
use CSG::Mapper::DB;
use CSG::Mapper::Job;
use CSG::Mapper::Logger;
use CSG::Mapper::Sample;

my $schema = CSG::Mapper::DB->new();

sub opt_spec {
  return (
    ['limit|l=i',         'Limit number of jobs to submit'],
    ['procs|p=i',         'Number of cores to request'],
    ['memory|m=i',        'Amount of memory to request, in MB'],
    ['walltime|w=s',      'Amount of wallclock time for this job'],
    ['delay=i',           'Amount of time to delay exection in seconds'],
    ['meta-id=i',         'Job meta record for parent job'],
    ['tmp-dir=s',         'Where to write fastq files'],
    ['sample=s',          'Sample id to submit (e.g. NWD123456)'],
    ['exclude-host=s@',   'Exclude samples that would fall on a specific host(s) (e.g. topmed3, topmed4)'],
    ['exclude-center=s@', 'Exclude samples that came from specific center(s) (e.g. illumina)'],
    ['skip-alignment',    'Cleanup after alignment failure (i.e. cloud-align worked, crams were downloaded, but vaildation failed)'],
    ['requested',         'Run only samples that are in the requested state'],
    [
      'step=s',
      'Job step to launch (valid values: bam2fastq|align|cloud-align|all|mapping|merging)', {
        default   => 'all',
        callbacks => {
          regex => sub {shift =~ /bam2fastq|local\-align|cloud\-align|all|mapping|merging/},
        }
      }
    ], [
      'next-step=s',
      'Submit alignment job if the step was bam2fastq', {
        default   => 'none',
        callbacks => {
          regex => sub {shift =~ /none|align/},
        }
      }
    ],
  );
}

sub validate_args {
  my ($self, $opts, $args) = @_;

  my $config = CSG::Mapper::Config->new(project => $self->app->global_options->{project});
  $self->{stash}->{config} = $config;

  my $step = $schema->resultset('Step')->find({name => $opts->{step}});
  unless ($step) {
    $self->usage_error('Invalid step specified');
  }
  $self->{stash}->{step} = $step;

  if ($opts->{meta_id}) {
    my $meta = $schema->resultset('Job')->find($opts->{meta_id});
    unless ($meta) {
      $self->usage_error('Invalid meta job id');
    }
    $self->{stash}->{meta} = $meta;
  }

  if ($opts->{'tmp_dir'}) {
    unless (-e $opts->{'tmp_dir'} and -r $opts->{'tmp_dir'}) {
      $self->usage_error('Temporary disk space does not exist or is not writable');
    }
  }
}

sub execute {
  my ($self, $opts, $args) = @_;

  my $debug   = $self->app->global_options->{debug};
  my $verbose = $self->app->global_options->{verbose};
  my $cluster = $self->app->global_options->{cluster};
  my $project = $self->app->global_options->{project};
  my $build   = $self->app->global_options->{build};

  my $jobs   = 0;
  my $config = $self->{stash}->{config};
  my $step   = $self->{stash}->{step};

  my $project_dir  = qq{$FindBin::Bin/..};
  my $prefix       = $config->get($cluster, 'prefix');
  my $workdir      = $config->get($project, 'workdir');
  my $base_tmp_dir = $opts->{tmp_dir} // $config->get($cluster, 'tmp_dir');

  ## no tidy
  my $procs = ($opts->{procs})
    ? $opts->{procs}
    : ($config->get($project, $step->name . '_procs'))
      ? $config->get($project, $step->name . '_procs')
      : $config->get($cluster, $step->name . '_procs');

  my $memory = ($opts->{memory})
    ? $opts->{memory}
    : ($config->get($project, $step->name . '_memory'))
      ? $config->get($project, $step->name . '_memory')
      : $config->get($cluster, $step->name . '_memory');

  my $walltime = ($opts->{walltime})
    ? $opts->{walltime}
    : ($config->get($project, $step->name . '_walltime'))
      ? $config->get($project, $step->name . '_walltime')
      : $config->get($cluster, $step->name . '_walltime');
  ## use tidy


  my $search       = {};
  my $attrs        = {order_by => 'RAND()'};
  my $dep_job_meta = $self->{stash}->{meta};

  if ($dep_job_meta) {
    $search->{id} = $dep_job_meta->result->sample->id;
    $attrs = {};

  } elsif ($opts->{sample}) {
    $search->{sample_id} = $opts->{sample};
    $attrs = {};

  } else {
    if ($opts->{exclude_host}) {
      $search->{'host.name'} = {-not_in => $opts->{exclude_host}};
      push @{$attrs->{join}}, 'host';
    }

    if ($opts->{exclude_center}) {
      $search->{'center.name'} = {-not_in => $opts->{exclude_center}};
      push @{$attrs->{join}}, 'center';
    }
  }

  for my $sample ($schema->resultset('Sample')->search($search, $attrs)) {
    last if $opts->{limit} and $jobs >= $opts->{limit};
    my $logger = CSG::Mapper::Logger->new();

    unless ($sample->is_available($step->name, $build)) {
      $logger->info('sample ' . $sample->sample_id . ' is not available for processing') if $debug;
      next;
    }

    if ($opts->{requested}) {
      unless ($sample->is_requested($step->name, $build)) {
        $logger->info('sample ' . $sample->sample_id . ' is not in requested state') if $debug;
        next;
      }
    }

    if ($step->name =~ /(?:cloud|local)\-align/) {
      unless ($sample->fastqs->count) {
        $logger->debug('no fastq files recorded for sample ' . $sample->sample_id) if $debug;
        next;
      }

      if ($sample->has_fastqs_with_unpaired_reads) {
        $logger->debug('found unpaired reads in the fastqs for sample ' . $sample->sample_id) if $debug;
        next;
      }
    }

    my $sample_obj = CSG::Mapper::Sample->new(
      cluster => $cluster,
      record  => $sample,
      build   => $build
    );

    try {
      $sample_obj->incoming_path;
      $logger->debug('incoming_path: ' . $sample_obj->incoming_path) if $debug;
    }
    catch {
      if (not ref $_) {
        $logger->critical('Uncaught exception');
        $logger->error($_);

      } elsif ($_->isa('CSG::Mapper::Exceptions::Sample::NotFound')) {
        $logger->error($_->description);
        $logger->error('bam_path: ' . $_->bam_path);
        $logger->error('cram_path: ' . $_->cram_path);

      } elsif ($_->isa('CSG::Mapper::Exceptions::Sample::SlotFailed')) {
        $logger->error($_->error);

      } else {
        if ($_->isa('Exception::Class')) {
          chomp(my $error = $_->error);
          $logger->critical($error);
        } else {
          $logger->critical('something went sideways');
          print STDERR Dumper $_ if $debug;
        }
      }
    };

    next unless $sample_obj->has_incoming_path;

    my $tmp_dir = File::Spec->join($base_tmp_dir, $project, $sample_obj->build_str, $sample->sample_id);

    if ($opts->{step} eq 'all') {
      $tmp_dir = File::Spec->join($base_tmp_dir, $project, $sample_obj->build_str, $opts->{step});
    }

    my $result = $schema->resultset('Result')->find(
      {
        sample_id => $sample->id,
        build     => $build,
      }
    );

    unless ($dep_job_meta) {
      unless ($result) {
        $result = $sample->add_to_results({build => $build});
      }
    }

    my $delay = $opts->{delay} // int(rand($MAX_DELAY));
    my $job_meta = $schema->resultset('Job')->create(
      {
        cluster  => $cluster,
        procs    => $procs,
        memory   => $memory,
        walltime => $walltime,
        delay    => $delay,
        tmp_dir  => $tmp_dir,
      }
    );

    $logger->job_id($job_meta->id);

    if ($debug) {
      $logger->debug("cluster: $cluster");
      $logger->debug("procs: $procs");
      $logger->debug("memory: $memory");
      $logger->debug("walltime: $walltime");
      $logger->debug("delay: $delay");
      $logger->debug("build: $build");
      $logger->debug("tmp_dir: $tmp_dir");
      $logger->debug('out_dir: ' . $sample_obj->result_path);
    }

    my $basedir = File::Spec->join($prefix, $workdir);
    $logger->debug("basedir: $basedir") if $debug;
    unless (-e $basedir) {
      make_path($basedir);
      $logger->debug('created basedir') if $debug;
    }

    my $log_dir = $sample_obj->log_dir;
    $logger->debug("log_dir: $log_dir") if $debug;
    unless (-e $log_dir) {
      make_path($log_dir);
      $logger->debug('created log_dir') if $debug;
    }

    my $run_dir = $sample_obj->state_dir;
    $logger->debug("run_dir: $run_dir") if $debug;
    unless (-e $run_dir) {
      make_path($run_dir);
      $logger->debug('created run_dir') if $debug;
    }

    my $gotcloud_conf =
      File::Spec->join($project_dir, $config->get('gotcloud', 'gotcloud_conf') . $PERIOD . $sample_obj->build_str);
    $logger->debug("gotcloud conf: $gotcloud_conf") if $debug;
    unless (-e $gotcloud_conf) {
      $logger->critical(qq{Unable to locate GOTCLOUD_CONF [$gotcloud_conf]});
      exit 1;
    }

    my $gotcloud_root = File::Spec->join($basedir, $config->get($cluster, 'gotcloud_root'));
    $logger->debug("gotcloud root: $gotcloud_root") if $debug;
    unless (-e $gotcloud_root) {
      $logger->critical(qq{GOTCLOUD_ROOT [$gotcloud_root] does not exist!});
      exit 1;
    }

    my $gotcloud_ref = File::Spec->join($prefix, $config->get('gotcloud', qq{build${build}_ref_dir}));
    $logger->debug("gotcloud ref_dir: $gotcloud_ref") if $debug;
    unless (-e $gotcloud_ref) {
      $logger->critical(qq{GOTCLOUD_REF_DIR [$gotcloud_ref] does not exist!});
      exit 1;
    }

    my $job_file =
      File::Spec->join($run_dir, join($DASH, ($step->name, $sample_obj->build_str, $cluster . '.sh')));
    my $tt = Template->new(INCLUDE_PATH => qq($project_dir/templates/batch/$project));

    my $fastq_bucket = $config->get($project, 'google_fastq_bucket');
    $logger->debug("google fastq bucket: $fastq_bucket") if $debug;
    unless ($fastq_bucket) {
      $logger->critical('Google Storage Bucket for fastqs is not defined!');
      exit 1;
    }

    my $cram_bucket = $config->get($project, 'google_cram_bucket');
    $logger->debug("google cram bucket: $cram_bucket") if $debug;
    unless ($cram_bucket) {
      $logger->critical('Google Storage Bucket for crams is not default!');
      exit 1;
    }

    ## no tidy
    my $params     = {sample => $sample_obj};
    $params->{job} = {
      procs            => $procs,
      memory           => $memory,
      walltime         => $walltime,
      build            => $build,
      email            => $config->get($project, 'email'),
      job_name         => join($DASH, ($project, $step->name, $sample_obj->build_str, $sample_obj->sample_id)),
      account          => $config->get($cluster, 'account'),
      workdir          => $log_dir,
      job_dep_id       => ($dep_job_meta) ? $dep_job_meta->job_id : undef,
      nodelist         => ($dep_job_meta) ? $dep_job_meta->node   : $sample->host->name,
      exclude_nodelist => join($COMMA, map {$_->name} $schema->resultset('Host')->search({name => {'!=' => 'csgspare'}})),
      jobs_cnt         => $jobs,
    };

    if ($params->{job}->{nodelist} eq 'csgspare') {
      $params->{job}->{nodelist} = 'topmed';
    }

    $params->{settings} = {
      tmp_dir         => $tmp_dir,
      job_log         => File::Spec->join($log_dir, 'job-info-' . $step->name . '-' . $cluster . '.yml'),
      pipeline        => $config->get('pipelines', $sample_obj->center) // $config->get('pipelines', 'default'),
      max_failed_runs => $config->get($project, 'max_failed_runs'),
      out_dir         => $sample_obj->result_path,
      run_dir         => $run_dir,
      project_dir     => $project_dir,
      delay           => $delay,
      threads         => $procs,
      meta_id         => $job_meta->id,
      mapper_cmd      => $PROGRAM_NAME,
      cluster         => $cluster,
      project         => $project,
      next_step       => $opts->{next_step},
      skip_alignment  => ($opts->{skip_alignment}) ? $TRUE : $FALSE,
    };

    $params->{gotcloud} = {
      root         => $gotcloud_root,
      conf         => $gotcloud_conf,
      ref_dir      => $gotcloud_ref,
      cmd          => File::Spec->join($gotcloud_root, 'gotcloud'),
      samtools     => File::Spec->join($gotcloud_root, 'bin', 'samtools'),
      bam_util     => File::Spec->join($gotcloud_root, '..', 'bamUtil', 'bin', 'bam'),
      bwa          => File::Spec->join($gotcloud_root, 'bin', 'bwa'),
      samblaster   => File::Spec->join($gotcloud_root, '..',  'samblaster', 'bin', 'samblaster'),    # TODO - need real path
      illumina_ref => File::Spec->join($prefix, $config->get('gotcloud', 'illumina_ref')),
    };

    $params->{google} = {
      fastq_bucket => $fastq_bucket,
      cram_bucket  => $cram_bucket,
    };
    ## use tidy

    if ($step->name eq 'cloud-align') {
      if ($sample->fastqs->count) {
        $params->{job}->{tmp_dir} = dirname($sample->fastqs->first->path);
        $job_meta->update({tmp_dir => $params->{job}->{tmp_dir}});

        my $path  = Path::Class->file($params->{job}->{tmp_dir});
        my @comps = $path->components();
        my $idx   = ($cluster eq 'csg') ? 3 : 4;

        $params->{job}->{nodelist} = $comps[$idx];
      }

      # XXX - if we want the delay to be based on all running jobs for this step
      #       may need to make it submitted rather than running though.
      #
      # my $running_cnt  = $schema->resultset('ResultsStatesStep')->running_by_step($build, $step->name)->count;
      # $logger->debug("running samples: $running_cnt") if $debug;
      # $params->{job}->{jobs_cnt} = $running_cnt + 1;

      my $rg_idx = 0;
      for my $read_group ($sample->read_groups) {
        push @{$params->{fastq}->{indexes}}, $rg_idx;

        my $rg_ref = {
          name  => $read_group,
          index => $rg_idx,
          delay => 0,
        };

        for my $fastq ($sample->fastqs->search({read_group => $read_group, aligned_at => undef})) {
          my ($name, $path, $suffix) = fileparse($fastq->path, $FASTQ_SUFFIX);
          my $cram = File::Spec->join($sample_obj->result_path, qq{$name.cram});

          my $fastq_file = qq{${name}${suffix}};
          my $fastq_uri  = URI->new($fastq_bucket);

          $fastq_uri->path($fastq->sample->sample_id . $SLASH . $fastq_file);

          my $fastq_ref = {
            cram           => $cram,
            fastq          => $fastq_file,
            fastq_read_cnt => $fastq->read_cnt,
          };

          if ($fastq->path =~ /_interleaved\.fastq\.gz$/) {
            $rg_ref->{paired}->{$fastq_uri->as_string}   = $fastq_ref;
          } else {
            $rg_ref->{unpaired}->{$fastq_uri->as_string} = $fastq_ref;
          }
        }

        $rg_idx++;
        push @{$params->{fastq}->{read_groups}}, $rg_ref;
      }
    } elsif ($step->name eq 'local-align') {
      unless ($sample->fastqs->count) {
        $logger->debug('no fastq files recorded for sample') if $verbose;
        next;
      }

      # TODO - going to do stack all the fastqs as tasks within a single job.
      #        this makes life much simpler.
    }

    $tt->process($step->name . q{.sh.tt2}, $params, $job_file) or die $tt->error();

    $logger->debug("wrote batch file to $job_file") if $debug;

    $jobs++;
    next if $self->app->global_options->{dry_run};

    my $job = CSG::Mapper::Job->new(cluster => $cluster);

    $logger->debug("submitting batch file $job_file") if $debug;

    try {
      $job->submit($job_file);

      $logger->info('submitted job (' . $job->job_id . ') for sample ' . $sample_obj->sample_id) if $verbose;

      $result->add_to_results_states_steps(
        {
          state_id => $schema->resultset('State')->find({name => 'submitted'})->id,
          step_id  => $step->id,
          job_id   => $job_meta->id,
        }
      );

      $job_meta->update(
        {
          job_id       => $job->job_id() // undef, # FIXME - dummy cluster will not have a job_id to set
          submitted_at => $schema->now(),
        }
      );
    }
    catch {
      if (not ref $_) {
        $logger->critical('Uncaught exception');
        $logger->error($_);

      } elsif ($_->isa('CSG::Mapper::Exceptions::Job::BatchFileNotFound')) {
        $logger->error($_->description);

      } elsif ($_->isa('CSG::Mapper::Exceptions::Job::BatchFileNotReadable')) {
        $logger->error($_->description);

      } elsif ($_->isa('CSG::Mapper::Exceptions::Job::SubmissionFailure')) {
        $logger->error($_->description);

      } elsif ($_->isa('CSG::Mapper::Exceptions::Job::ProcessOutput')) {
        $logger->error($_->description);
        $logger->error($_->output);

      } else {
        if ($_->isa('Exception::Class')) {
          chomp(my $error = $_->error);
          $logger->critical($error);
        } else {
          $logger->critical('something went sideways');
          print STDERR Dumper $_ if $debug;
        }
      }
    };
  }
}

1;

__END__

=head1

CSG::Mapper::Command::launch - Launch remapping jobs
