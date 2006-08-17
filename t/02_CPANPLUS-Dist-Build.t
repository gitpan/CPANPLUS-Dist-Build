BEGIN { chdir 't' if -d 't' };

### this is to make devel::cover happy ###
BEGIN {
    use File::Spec;
    require lib;
    for (qw[../lib inc]) {
        my $l = 'lib'; $l->import(File::Spec->rel2abs($_)) 
    }
}

use strict;
use CPANPLUS::Configure;
use CPANPLUS::Backend;
use CPANPLUS::Internals::Constants;
use CPANPLUS::Module::Fake;
use CPANPLUS::Module::Author::Fake;

use Config;
use Test::More      'no_plan';
use File::Basename  ();
use Data::Dumper;
use Config;
use IPC::Cmd        'can_run';

$SIG{__WARN__} = sub {warn @_ unless @_ && $_[0] =~ /redefined|isn't numeric/};

# Load these two modules in advance, even though they would be
# auto-loaded, because we want to override some of their subs.
use ExtUtils::Packlist;
use ExtUtils::Installed;

my $Class   = 'CPANPLUS::Dist::Build';
my $Utils   = 'CPANPLUS::Internals::Utils';
my $Have_CC =  can_run($Config{'cc'} )? 1 : 0;


my $Lib     = File::Spec->rel2abs(File::Spec->catdir( qw[dummy-perl] ));
my $Src     = File::Spec->rel2abs(File::Spec->catdir( qw[src] ));

my $Verbose = @ARGV ? 1 : 0;
my $CB      = CPANPLUS::Backend->new;
my $Conf    = $CB->configure_object;

$Conf->set_conf( base       => 'dummy-cpanplus' );
$Conf->set_conf( dist_type  => '' );
$Conf->set_conf( verbose    => $Verbose );
$Conf->set_conf( signature  => 0 );
### running tests will mess with the test output so skip 'm
$Conf->set_conf( skiptest   => 1 );

                # path, cc needed?
my %Map     = ( noxs    => 0,
                xs      => 1 
            );        


### Disable certain possible settings, so we dont accidentally
### touch anything outside our sandbox
{   
    ### set buildflags to install in our dummy perl dir
    $Conf->set_conf( buildflags => "install_base=$Lib" );
    
    ### don't start sending test reports now... ###
    $CB->_callbacks->send_test_report( sub { 0 } );
    $Conf->set_conf( cpantest => 0 );
    
    ### we dont need sudo -- we're installing in our own sandbox now
    $Conf->set_program( sudo => undef );
}

use_ok( $Class );

ok( $Class->format_available,   "Format is available" );


while( my($path,$need_cc) = each %Map ) {

    ### create a fake object, so we don't use the actual module tree
    my $mod = CPANPLUS::Module::Fake->new(
                    module  => 'Foo::Bar',
                    path    => 'src',
                    author  => CPANPLUS::Module::Author::Fake->new,
                    package => 'Foo-Bar-0.01.tar.gz',
                );

    ok( $mod,                   "Module object created for '$path'" );        
                
    ### set the fetch location -- it's local
    {   my $where = File::Spec->rel2abs(
                            File::Spec->catdir( $Src, $path, $mod->package )
                        );
                        
        $mod->status->fetch( $where );

        ok( -e $where,          "   Tarball '$where' exists" );
    }

    ok( $mod->prepare,          "   Preparing module" );

    ok( $mod->status->dist_cpan,    
                                "   Dist registered as status" );

    isa_ok( $mod->status->dist_cpan, $Class );

    ok( $mod->status->dist_cpan->status->prepared,
                                "   Prepared status registered" );
    is( $mod->status->dist_cpan->status->distdir, $mod->status->extract,
                                "   Distdir status registered properly" );


    is( $mod->status->installer_type, INSTALLER_BUILD, 
                                "   Proper installer type found" );


    ### we might not have a C compiler
    SKIP: {
        skip("The CC compiler listed in Config.pm is not available " .
             "-- skipping compile tests", 5) if $need_cc && !$Have_CC;
        skip("Module::Build is not compiled with C support ".
             "-- skipping compile tests", 5) 
             unless Module::Build->_mb_feature('C_support');

        ok( $mod->create( ),    "Creating module" );
        ok( $mod->status->dist_cpan->status->created,
                                "   Created status registered" );

        ### install tests
        SKIP: {
            skip("Install tests require Module::Build 0.2606 or higher", 2)
                unless $Module::Build::VERSION >= '0.2606';
        
            ### flush the lib cache
            ### otherwise, cpanplus thinks the module's already installed
            ### since the blib is already in @INC
            $CB->_flush( list => [qw|lib|] );
        
            ### force the install, make sure the Dist::Build->install()
            ### sub gets called
            ok( $mod->install( force => 1 ),
                                "Installing module" ); 
            ok( $mod->status->installed,    
                                "   Status says module installed" );
        }

        SKIP: {
            my $minversion = 0.2609;
            skip(qq[Uninstalling requires at least Module::Build $minversion], 1)
              unless eval { Module::Build->VERSION($minversion); 1 };

            # The installation directory actually needs to be in @INC
            # in order to test uninstallation
            'lib'->import( File::Spec->catdir($Lib, 'lib', 'perl5') );

            # EU::Installed and CP+::M are only capable of searching
            # for modules in the core directories.  We need to fake
            # them out with our own subs here.
            my $packlist = find_module($mod->name . '::.packlist');
            ok $packlist, "Found packlist";
            
            my $p = ExtUtils::Packlist->new($packlist);
            ok keys(%$p) > 0, "Packlist contains entries";

            local *CPANPLUS::Module::installed_version = sub {1};
            local *CPANPLUS::Module::packlist = sub { [$p] };
            local *ExtUtils::Installed::files = sub { keys %$p };
            
            ok( $mod->uninstall,"Uninstalling module" );
        }
    }

    ### throw away all the extracted stuff
    $Utils->_rmdir( dir => $Conf->get_conf('base') );
}

sub find_module {
  my $module = shift;

  # Don't add the .pm yet, in case it's a packlist or something like ExtUtils::xsubpp.
  my $file = File::Spec->catfile( split m/::/, $module );
  my $candidate;
  foreach (@INC) {
    if (-e ($candidate = File::Spec->catdir($_, $file))
        or
        -e ($candidate = File::Spec->catdir($_, "$file.pm"))
        or
        -e ($candidate = File::Spec->catdir($_, 'auto', $file))
        or
        -e ($candidate = File::Spec->catdir($_, 'auto', "$file.pm"))) {
      return $candidate;
    }
  }
  return;
}

# Local variables:
# c-indentation-style: bsd
# c-basic-offset: 4
# indent-tabs-mode: nil
# End:
# vim: expandtab shiftwidth=4:
