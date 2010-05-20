use ExtUtils::MakeMaker;

use YAML::Any qw(LoadFile);
my $file = "plugins/Send2PQ/config.yaml";
my $version = LoadFile($file)->{version} ||
    die "No version found in $file";

WriteMakefile(
    NAME            => 'Send to Publish Queue',
    VERSION         => $version,
    DISTNAME        => 'Send2PQ',
);
