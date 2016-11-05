#!/usr/bin/perl -w

use strict;
use warnings;

use autodie;
use Try::Tiny;
use AnyEvent;
use AnyEvent::HTTP;
use Getopt::Long;
use JSON;
use Data::Dumper;

binmode(STDIN, ":utf8");
binmode(STDOUT, ":utf8");
binmode(STDERR, ":utf8");

$ENV{TMPDIR} = "/tmp";

my %params = (
    dir => $ENV{TMPDIR},
    regexp => {
        boards => $ENV{BOARDS},
        files => $ENV{FILES},
    }   
);

GetOptions(
    "dir|d=s" => \$params{dir},
    "boards|b" => \$params{boards},
);


my $cv = AE::cv();

sub download($$$)
{
    my ($url, $file, $cb) = @_;

    open(my $fh, ">>", $file);

    my %headers = ();
    my $offset = 0;

    print STDERR stat($fh), "\n";
    print STDERR -s _, "\n";

    if (stat($fh) && -s _) 
    {
        $offset = -s _;
        print STDERR "-s is ", $offset, "\n";
        $headers{"if-unmodified-since"} = AnyEvent::HTTP::format_date + (stat _)[9];
        $headers{"range"} = "bytes=$offset-";
    }

    http_get($url,
        headers   => \%headers,
        on_header => sub {
            my ($headers) = @_;

            if ($$headers{Status} == 200 && $offset) 
            {
                # resume failed
                truncate($fh, $offset = 0);
            }

            sysseek($fh, $offset, 0);

            1
        },
        on_body   => sub {
            my ($data, $headers) = @_;

            if ($$headers{Status} =~ /^2/) 
            {
                length($data) == syswrite($fh, $data) or return; # abort on write errors
            }

            1
        },
        sub {
            my (undef, $headers) = @_;

            my $status = $$headers{Status};

            if (my $time = AnyEvent::HTTP::parse_date($$headers{"last-modified"})) 
            {
                utime($time, $time, $file);
            }

            if ($status == 200 || $status == 206 || $status == 416) 
            {
                # download ok || resume ok || file already fully downloaded
                $cb->(1, $headers);
            } 
            elsif ($status == 412) 
            {
                # file has changed while resuming, delete and retry
                unlink($file);
                $cb->(0, $headers);

            } 
            elsif ($status == 500 or $status == 503 or $status =~ /^59/) 
            {
                # retry later
                $cb->(0, $headers);
            } 
            else 
            {
                $cb->(undef, $headers);
            }

            close($fh);
        }
    );
}

sub get_4chan_data($$)
{
    my ($url, $cb) = @_;

    my $json_parser = JSON->new(); 
    my $data;

    http_get($url, 
        headers => {

        },
        on_header => sub {
            my ($headers) = @_;

            1
        },
        on_body => sub {
            my ($json, $headers) = @_;

            if($$headers{Status} =~ /^2/)
            {
                $data = $json_parser->incr_parse($json);
            }

            1 
        },
        sub {
            my (undef, $headers) = @_;

            my $status = $$headers{Status};          

            if ($status == 200)
            {   
                $cb->($data, $headers);
            }
            elsif ($status == 500 || $status == 503 || $status =~ /^59/)
            {
                $cb->(0, $headers);
            }
            else
            {   
                $cb->(undef, $headers);
            }
        }       
    );    
}



sub get_file($$$)
{
    my ($board, $post, $semantic_url_dir) = @_;

    print STDERR "get_file\n";

    if(defined($$post{tim}) && defined($$post{ext}))
    {
        my $url = "http://i.4cdn.org/$$board{board}/$$post{tim}$$post{ext}";

        $cv->begin();

        download($url, "$semantic_url_dir/$$post{tim}$$post{ext}", sub {
                my ($download_status, $headers) = @_;

                if ($download_status) 
                {
                    print $url, 
                    " -> $semantic_url_dir/$$post{tim}$$post{ext} - download complete !\n";
                } 
                elsif (defined($download_status)) 
                {
                    print STDERR $url, 
                    " -> $semantic_url_dir/$$post{tim}$$post{ext} - download failed, please retry later !\n";
                } 
                else 
                {
                    print STDERR $url, 
                    " -> $semantic_url_dir/$$post{tim}$$post{ext} - download failed, HTTP Status Code: ", 
                    $$headers{Status}, 
                    ", Reason: ", 
                    $$headers{Reason}, 
                    "\n";
                }

                $cv->end();
            }
        );
    }

}

sub get_thread($$)
{
    my ($board, $thread) = @_;

    print STDERR "get_thread\n";

    my $semantic_url_dir = "$params{dir}/4chan/$$thread{semantic_url}";

    if(! -d $semantic_url_dir)
    {
        mkdir($semantic_url_dir);
    }

    $cv->begin();

    get_4chan_data("http://a.4cdn.org/$$board{board}/thread/$$thread{no}.json", sub {

            my ($data, $headers) = @_;

            if($data)
            {   
                for my $post (@{$$data{posts}})
                {
                    get_file($board, $post, $semantic_url_dir);
                }
            }

            $cv->end();
        }
    );
}

sub get_catalog($)
{
    my ($board) = @_;

    print STDERR "get_catalog\n";

    $cv->begin();

    get_4chan_data("http://a.4cdn.org/$$board{board}/catalog.json", sub {

            my ($data, $headers) = @_;

            if($data)
            {  
                for my $page (@{$data})
                {
                    for my $thread (@{$$page{threads}})
                    {

                            get_thread($board, $thread);

                    }
                }
            }


            $cv->end();
        }  
    );


}

sub get_boards()
{   
    $cv->begin();

    get_4chan_data("http://a.4cdn.org/boards.json", sub {
            my ($data, $headers) = @_;

            if($data) 
            {
                for my $board (@{$$data{boards}})
                {
                    if($$board{board} =~ $$params{regexp}{boards})
                    {
                        get_catalog($board);
                    }
                }
            }

            $cv->end(); 
        }
    );
}


try
{
    for my $key (keys %{$$params{regexp}})
    {
        if(defined($$params{regexp}{$key}))
        {
            $$params{regexp}{$key} = qr/$$params{regexp}{$key}/;
        }
    }

    if(! -d "$params{dir}/4chan")
    {
        mkdir("$params{dir}/4chan");
    }

    get_boards();

    $cv->recv();
}
catch
{
    my ($err) = @_;

    print STDERR $err;
};
