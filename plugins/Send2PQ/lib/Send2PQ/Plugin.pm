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
        if (MT->model('ts_job')->exist( $batch->id )) {
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

sub send_to_queue {
    my $app = shift;
    my ($param) = @_;
    my $q       = $app->{query};
    $param ||= {};

    return unless $app->blog;

    if ($q->param('create_job')) {
        my $batch = MT->model('pub_batch')->new;
        $batch->blog_id( $app->blog->id );
        $batch->email( $q->param('email') );
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
        $pub->rebuild( Blog => $app->blog );
        return $app->load_tmpl( 'dialog/close.tmpl' );
    }
    $param->{batch_exists}  = MT->model('pub_batch')->exist({ blog_id => $app->blog->id });
    $param->{blog_id}       = $app->blog->id;
    $param->{default_email} = $app->user->email;
    return $app->load_tmpl( 'dialog/send_to_queue.tmpl', $param );
}

# Adds every non-disabled template to the publish queue. 
# This is a near copy of the build_file_filter in MT::WeblogPublisher
sub send_all_to_queue {
    my ( $cb, %args ) = @_;

    require MT::Request;
    my $r = MT::Request->instance();
    my $batch = $r->stash('publish_batch');

    unless ($batch) {
        # Batch does not exist, so assume we can publish. Let other build_file_filters determine
        # course of action.
        return 1;
    }

    my $fi = $args{file_info};
#    return 1 if $fi->{from_queue};

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

    my $priority = _get_job_priority($fi);

    require MT::TheSchwartz;
    require TheSchwartz::Job;
    my $job = TheSchwartz::Job->new();
    $job->funcname('MT::Worker::Publish');
    $job->uniqkey( $fi->id );
    if ($job->has_column('batch_id')) {
        $job->batch_id( $batch->id );
    }
    $job->priority( $priority );
    $job->coalesce( ( $fi->blog_id || 0 ) . ':' . $$ . ':' . $priority . ':' . ( time - ( time % 10 ) ) );
    MT::TheSchwartz->insert($job);

    return 0;
}

sub _get_job_priority {
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
