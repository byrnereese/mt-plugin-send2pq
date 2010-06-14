package Send2PQ::Plugin;

use strict;
use MT::Util qw( format_ts );

sub load_tasks {
    my $cfg = MT->config;
    return {
        'PublishBatchCleanUp' => {
            'label' => 'Cleanup Finished Publish Batches',
            'frequency' => 1, #3 * 60,
            'code' => sub { 
                Send2PQ::Plugin->task_cleanup; 
            }
        }
    };
}

sub task_cleanup {
    my $this = shift;
    require MT::Util;
    my $mt = MT->instance;
    my @batches = MT->model('pub_batch')->load();
    foreach my $batch (@batches) {
        if (MT->model('ts_job')->exist( { batch_id => $batch->id } )) {
            # do nothing at this time
            # possible future: see how long the job has been on the queue, send warning if it has
            # been on the queue too long
        } else {
            if ($batch->email) {
                MT->log({ 
                    message => "It appears the publishing batch with an ID of " .$batch->id. " has finished. Notifying " . $batch->email . " and cleaning up.",
                    class   => "system",
                    blog_id => $batch->blog->id,
                    level   => MT::Log::INFO()
                });
                my $date = format_ts( "%Y-%m-%d", $batch->created_on, $batch->blog, undef );
                require MT::Mail;
                my %head = ( To => $batch->email, Subject => '['.$batch->blog->name.'] Publishing Batch Finished' );
                my $body = "The publishing batch you initiated on $date has completed. See for yourself:\n\n" . $batch->blog->site_url . "\n\n";
                MT::Mail->send(\%head, $body)
                    or die MT::Mail->errstr;
            } else {
                MT->log({
                    message => "It appears the publishing batch with an ID of " .$batch->id. " has finished. Cleaning up.",
                    class   => "system",
                    blog_id => $batch->blog->id,
                    level   => MT::Log::INFO()
                });
            }
            $batch->remove;
        }
    }
}

sub send_blogs_to_queue {
    my $app = shift;
    my ($param) = @_;
    my $q       = $app->{query};
    $param ||= {};
    if ( $q->param('create_job') ) {
        my @blog_ids = split(/,/, $q->param('blog_ids') );
        foreach my $blog_id (@blog_ids) {
            _create_batch( $blog_id, $q->param('email') );
        }
        return $app->load_tmpl( 'dialog/close.tmpl' );
    }
    $param->{blog_ids}       = join( ',', $q->param('id') );
    $param->{default_email} = $app->user->email;
    return $app->load_tmpl( 'dialog/send_to_queue.tmpl', $param );
}

sub send_to_queue {
    my $app = shift;
    my ($param) = @_;
    my $q       = $app->{query};
    $param ||= {};

    return unless $app->blog;

    if ($q->param('create_job')) {
        _create_batch( $app->blog->id, $q->param('email') );
        return $app->load_tmpl( 'dialog/close.tmpl' );
    }
    $param->{batch_exists}  = MT->model('pub_batch')->exist({ blog_id => $app->blog->id });
    $param->{blog_id}       = $app->blog->id;
    $param->{default_email} = $app->user->email;
    return $app->load_tmpl( 'dialog/send_to_queue.tmpl', $param );
}

sub _create_batch {
    my ($blog_id, $email) = @_;
    my $app = MT->instance;

    # Skip this blog if it's already marked to republish.
    return if ( MT->model('pub_batch')->exist({ blog_id => $blog_id }) );

    my $batch = MT->model('pub_batch')->new;
    $batch->blog_id( $blog_id );
    $batch->email( $email );
    $batch->save
        or return $app->error(
            $app->translate(
                "Unable to create a publishing batch and send content to the publish queue",
                $batch->errstr
            )
        );

    require MT::Request;
    my $r = MT::Request->instance();
    $r->stash('publish_batch',$batch);

    require MT::WeblogPublisher;
    my $pub = MT::WeblogPublisher->new;
    $pub->rebuild( BlogID => $blog_id );
}

# This callback is called when a file is successfully published. Let's use
# this to remove any requests to rebuild the same file from the publish
# queue. This will help reduce needless republishing.
# Keep in mind though that this will not be called if the contents of the
# published file has not changed.
sub build_file {
    my ( $cb, %args ) = @_;
    my $fi = $args{file_info};
    my $job = MT->model('ts_job')->load({ uniqkey => $fi->id });
    MT->log("Request to build");
    # Only remove jobs added by this plugin.
    if ($job && $job->batch_id > 0) {
        # A file has been rebuilt by some other process. Let's go
        # ahead and remove it from the queue since there is not need
        # to publish it twice.
        $job->remove or MT->log("Could not remove file from queue.");
    }
}

# Adds every non-disabled template to the publish queue. 
# This is a near copy of the build_file_filter in MT::WeblogPublisher
sub send_all_to_queue {
    my ( $cb, %args ) = @_;

    require MT::Request;
    my $r = MT::Request->instance();
    my $batch = $r->stash('publish_batch');
    my $fi = $args{file_info};

    unless ($batch) {
        # Batch does not exist, so assume we can publish. Let other build_file_filters determine
        # course of action.
        # In other words, this publish request is coming from somewhere else other than a user
        # initiating a "Publish via Queue" method. So short circuit.

        # However, before we just pass on a chance to do something useful, let's see if a job
        # already exists on the queue for the corresponding file. If so, let's do one of two
        # things:
        #   a) TODO - if the file is getting published synchronously - REMOVE IT from the queue
        #   b) increase the priority of the job, for each request to publish it

        my $job = MT->model('ts_job')->load({ uniqkey => $fi->id });
        if ($job) {
            # The job exists! Ok, so if its current priority is less than its default
            # then let's increment the priority so that the more often a file is asked to be 
            # rebuilt, the higher the priority it will become.
            my $max_priority = _get_default_job_priority($fi);
            if ($job->priority < $max_priority) {
                $job->priority( $job->priority + 1 );
                $job->save;
            }
        }

        return 1;
    }

    # If we have gotten this far, then we know for sure that the request to build this
    # file has come from a user asking Send to Queue to do so.
    # The job *may* already exist on the queue, if so, let's just let TheSchwartz decide
    # what to do.

    require MT::PublishOption;
    my $throttle = MT::PublishOption::get_throttle($fi);

    # Prevent building of disabled templates if they get this far
    return 0 if $throttle->{type} == MT::PublishOption::DISABLED();

    # Check for 'force' flag for 'manual' publish option, which
    # forces the template to build; used for 'rebuild' list actions
    # and publish site operations
    if ($throttle->{type} == MT::PublishOption::MANUALLY()) {
        return $args{force} ? 1 : 0;
    }

    # Let's default to the lowest priority possible. That way a request to republish a 
    # HUGE site will not penalize the priority of jobs not yet added to the queue.
    # Further above though, this is compensated for because every time a request to 
    # build a file is made, Send2Queue will check to see if a job already exists for
    # that file and if so, increase its priority.
    #my $priority = _get_default_job_priority($fi);
    my $priority = 1;

    require MT::TheSchwartz;
    my $ts = MT::TheSchwartz->instance();
    my $func_id = $ts->funcname_to_id($ts->driver_for,$ts->shuffled_databases,'MT::Worker::Publish');

    my $job = MT->model('ts_job')->new();
    $job->uniqkey( $fi->id );
    $job->funcid( $func_id );
    if ($job->has_column('batch_id')) {
        $job->batch_id( $batch->id );
    }
    $job->priority( $priority );
    $job->grabbed_until(1);
    $job->run_after(1);
    $job->coalesce( ( $fi->blog_id || 0 ) . ':' . $$ . ':' . 
                    $priority . ':' . ( time - ( time % 10 ) ) );

    # Note to self - this does not appear to utilize TheSchwart's insert 
    # routine. Should this be fixed?
    $job->save or MT->log({
        blog_id => $fi->blog_id,
        message => "Could not queue publish job for Send2Q: " . $job->errstr
    });

    return 0;
}

# This logic replicates MT's prioritization scheme.
sub _get_default_job_priority {
    my ($fi) = @_;
    my $priority = 0;
    my $at = $fi->archive_type || '';
    # Default priority assignment....
    if (($at eq 'Individual') || ($at eq 'Page')) {
        require MT::TemplateMap;
        my $map = MT::TemplateMap->load($fi->templatemap_id);
        # Individual/Page archive pages that are the 'permalink' pages
        # should have highest build priority.
        if ($map && $map->is_preferred) {
            $priority = 10;
        } else {
            $priority = 5;
        }
    } elsif ($at eq 'index') {
        # Index pages are second in priority, if they are named 'index'
        # or 'default'
        if ($fi->file_path =~ m!/(index|default|atom|feed)!i) {
            $priority = 9;
        } else {
            $priority = 8;
        }
    } elsif ($at =~ m/Category|Author/) {
        $priority = 1;
    } elsif ($at =~ m/Yearly/) {
        $priority = 1;
    } elsif ($at =~ m/Monthly/) {
        $priority = 2;
    } elsif ($at =~ m/Weekly/) {
        $priority = 3;
    } elsif ($at =~ m/Daily/) {
        $priority = 4;
    }
    return $priority;
}

1;
__END__
