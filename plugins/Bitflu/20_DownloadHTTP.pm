package Bitflu::DownloadHTTP;
#
# This file is part of 'Bitflu' - (C) 2006-2007 Adrian Ulrich
#
# Released under the terms of The "Artistic License 2.0".
# http://www.perlfoundation.org/legal/licenses/artistic-2_0.txt
#
# Fixme: We do not write performance stats (kib up / down)
#


use strict;
use Digest::SHA1;

use constant HEADER_SIZE_MAX    => 64*1024;   # Size limit for http-headers (64kib should be enough for everyone ;-) )
use constant PICKUP_DELAY       => 30;        # How often shall we scan the queue for 'lost' downloads
use constant TIMEOUT_DELAY      => 60;        # Re-Connect to server if we did not read data within X seconds
use constant STORAGE_TYPE       => 'http';    # Storage Type identifier, do not change.
use constant ESTABLISH_MAXFAILS => 10;        # Drop download if we still could not get a socket after X attemps

##########################################################################
# Registers the HTTP Plugin
sub register {
	my($class, $mainclass) = @_;
	my $self = { super => $mainclass, nextpickup => 0, lastrun => 0, dlx => { get_socket => {}, has_socket => {} } };
	bless($self,$class);
	
	$self->{http_maxthreads} = ($mainclass->Configuration->GetValue('http_maxthreads') || 10);
	$mainclass->Configuration->SetValue('http_maxthreads', $self->{http_maxthreads});
	my $main_socket = $mainclass->Network->NewTcpListen(ID=>$self, Port=>0, MaxPeers=>$self->{http_maxthreads});
	$mainclass->AddRunner($self);
	return $self;
}

##########################################################################
# Regsiter admin commands
sub init {
	my($self) = @_;
	$self->{super}->Admin->RegisterCommand('load', $self, 'StartHTTPDownload', "Start download of HTTP-URL",
	  [ [undef, "Bitflu can load files via HTTP (like wget)"], [undef, "To start a http download use: 'load http://www.example.com/foo/bar.tgz'"] ] );
	return 1;
}

##########################################################################
# Restarts an existing download
sub resume_this {
	my($self, $sid) = @_;
	my $so = $self->{super}->Storage->OpenStorage($sid) or $self->panic("Unable to open/resume $sid");
	$self->SetupStorage(Hash=>$sid); # Request to initialize existing storage / Add the item to queuemgr
}

##########################################################################
# Fire up download
sub StartHTTPDownload {
	my($self, @args) = @_;
	my @A    = ();
	my $hits = 0;
	foreach my $arg (@args) {
		if(my ($xhost,$xport,$xurl) = $arg =~ /^http:\/\/([^\/:]+):?(\d*)\/(.+)$/i) {
			$xport ||= 80;
			$xhost = lc($xhost);
			$hits++;
			my $xuri = "http://$xhost:$xport/$xurl";
			my ($xsha,$xactive) = $self->_InitDownload(Host=>$xhost, Port=>$xport, Url=>$xurl);
			
			if($xactive != 0) {
				push(@A, [2, "$xsha : Download exists in queue and is still active"]);
			}
			elsif($self->{super}->Storage->OpenStorage($xsha)) {
				push(@A, [2, "$xsha : Download exists in queue"]);
				delete($self->{dlx}->{get_socket}->{$xsha}) or $self->panic("Unable to remove get_socket for $xsha !");
			}
			else {
				push(@A, [1, "$xsha : Download started"]);
			}
		}
	}
	return({CHAINSTOP=>$hits, MSG=>\@A});
}

##########################################################################
# Create new HTTP-Superfunk object ; kicking the HTTP-Requester
sub _InitDownload {
	my($self, %args) = @_;
	my $xsha = Digest::SHA1::sha1_hex("http://$args{Host}:$args{Port}/$args{Url}");
	
	my ($xname) = $args{Url};# =~ /([^\/]+)$/;
	
	my $xactive = 0;
	
	# Check if request to start this download was sent before:
	if ( defined($self->{dlx}->{get_socket}->{$xsha}) ) {
		$self->warn("$xsha : Still getting socket...");
		$xactive++;
	}
	foreach my $xsk (keys(%{$self->{dlx}->{has_socket}})) {
		if($self->{dlx}->{has_socket}->{$xsk}->{Hash} eq $xsha) {
			$self->warn("$xsha : Still reading header...");
			$xactive++;
		}
	}
	
	if($xactive == 0) {
		$self->{dlx}->{get_socket}->{$xsha} = { Host => $args{Host}, Port => $args{Port}, Url=> $args{Url}, LastRead => $self->{super}->Network->GetTime, Xfails => 0,
		                                        Range => 0, Offset => int($args{Offset}), Hash => $xsha , Name => $xname, GotHeader => 0};
	}
	return ($xsha,$xactive);
}


##########################################################################
# Creates a new storage
sub SetupStorage {
	my($self, %args) = @_;
	
	my $so = undef;
	
	my $stats_size = -1;
	my $stats_done = -1;
	
	if($so = $self->{super}->Storage->OpenStorage($args{Hash})) {
		$self->debug("Opened existing storage for $args{Hash}");
		if($so->IsSetAsFree(0))    { $so->SetAsInwork(0) }
		$stats_done = ($so->IsSetAsInwork(0) ? $so->GetSizeOfInworkPiece(0) : $so->GetSizeOfDonePiece(0) );
		$stats_size = $so->GetSetting('size');
	}
	else {
		$self->info("Creating new storage for $args{Hash} ($args{Size})");
		my @pathref = split('/',$args{Host}."/".$args{Name});
		my $name    = $pathref[-1];
		$so = $self->{super}->Queue->AddItem(Name=>$name, Chunks => 1, Overshoot => 0, Size => $args{Size}, Owner => $self,
		                                     ShaName => $args{Hash}, FileLayout => { $args{Name} => { start => 0, end => $args{Size}, path=>\@pathref } });
		$self->panic("Adding $args{Hash} to Queue failed") unless defined($so);
		$so->SetSetting('type', STORAGE_TYPE) or $self->panic;
		$so->SetSetting('_host', $args{Host}) or $self->panic;
		$so->SetSetting('_port', $args{Port}) or $self->panic;
		$so->SetSetting('_url',  $args{Url})  or $self->panic;
		$stats_size = $args{Size};
		$stats_done = 0;
		$so->SetAsInwork(0);
		$so->Truncate(0); # Do not do funny things
	}
	
	$self->{super}->Queue->SetStats($args{Hash}, {total_bytes=>$stats_size, done_bytes=>$stats_done, uploaded_bytes=>0,
	                                              total_chunks=>1, done_chunks=>($so->IsSetAsDone(0) ? 1 : 0 )});
	return $so;
}





sub run {
	my($self) = @_;
	
	$self->{super}->Network->Run($self, {Accept=>'_Network_Accept', Data=>'_Network_Data', Close=>'_Network_Close'});
	my $NOW = $self->{super}->Network->GetTime;
	
	if( $NOW > $self->{nextpickup} ) {
		$self->_Pickup;
	}
	
	if( $NOW != $self->{lastrun} ) {
	$self->{lastrun} = $NOW;
	foreach my $nsock (keys(%{$self->{dlx}->{get_socket}})) {
			# Establish new TCP-Connections
			my $new_sock = $self->{super}->Network->NewTcpConnection(ID=>$self, Port=>$self->{dlx}->{get_socket}->{$nsock}->{Port},
			                                                         Ipv4=>$self->{dlx}->{get_socket}->{$nsock}->{Host}, Timeout=>5);
			if(defined($new_sock)) {
				my $wdata  = "GET /$self->{dlx}->{get_socket}->{$nsock}->{Url} HTTP/1.1\r\n";
				   $wdata .= "Host: $self->{dlx}->{get_socket}->{$nsock}->{Host}\r\n";
				   $wdata .= "Range: bytes=".int($self->{dlx}->{get_socket}->{$nsock}->{Offset})."-\r\n";
				   $wdata .= "Connection: Close\r\n\r\n";
				$self->{super}->Network->WriteData($new_sock, $wdata) or $self->panic("Unable to write data to $new_sock !");
				$self->{dlx}->{has_socket}->{$new_sock} = delete($self->{dlx}->{get_socket}->{$nsock});
				$self->{dlx}->{has_socket}->{$new_sock}->{Socket} = $new_sock;
			}
			elsif(++$self->{dlx}->{get_socket}->{$nsock}->{Xfails} > ESTABLISH_MAXFAILS) {
				$self->warn("Dropping <$nsock> ; unable to establish connection");
				delete($self->{dlx}->{get_socket}->{$nsock}) or $self->panic("Unable to delete existing download");
			}
		}
	}
}

sub cancel_this {
	my($self,$sid) = @_;
	unless(delete($self->{dlx}->{get_socket}->{$sid})) {
		# -> Full search, nah!
		foreach my $qk (keys(%{$self->{dlx}->{has_socket}})) {
			if($self->{dlx}->{has_socket}->{$qk}->{Hash} eq $sid) {
				delete($self->{dlx}->{has_socket}->{$qk}) or $self->panic("Unable to delete $qk");
			}
		}
	}
	$self->{super}->Queue->RemoveItem($sid);
}

sub _Network_Data {
	my($self, $socket, $buffref) = @_;
	
	my $dlx = $self->{dlx}->{has_socket}->{$socket};
	unless(defined($dlx)) {
		$self->warn("Closing connection with $socket ; stale handle");
		$self->_KillClient($socket);
		return;
	}
	
	$dlx->{piggy} .= $$buffref;
	$$buffref     = '';

	if($dlx->{GotHeader} == 0) {
		my $bseen     = 0;
		foreach my $line (split(/\r\n/,$dlx->{piggy})) {
			$bseen += (2+length($line));
			
			if($line =~ /^Content-Length: (\d+)$/) {
				$dlx->{Length} = $1;
			}
			elsif($line =~ /^Content-Range: bytes (\d+)-/) {
				$dlx->{Range}  = $1;
			}
			
			if($bseen >= HEADER_SIZE_MAX) {
				$self->{super}->Admin->SendNotify("$dlx->{Hash}: HTTP-Header received from '$dlx->{Host}' is waaay too big ($bseen bytes) ; Dropping connection.");
				$self->_KillClient($socket);
				return;
			}
			elsif(length($line) == 0 && $dlx->{Length} == 0) {
				$self->{super}->Admin->SendNotify("$dlx->{Hash}: '$dlx->{Host}' did not specify size of download ; Dropping connection.");
				$self->_KillClient($socket);
				return;
			}
			elsif(length($line) == 0) {
				$dlx->{piggy} = substr($dlx->{piggy},$bseen);
				$dlx->{GotHeader} = 1;
				unless($dlx->{Storage}) {
					$dlx->{Storage} = $self->SetupStorage(Name=>$dlx->{Name}, Size=>$dlx->{Length}, Hash=>$dlx->{Hash},
					                                      Host=>$dlx->{Host}, Port=>$dlx->{Port}, Url=>$dlx->{Url});
				}
				$self->{super}->Queue->SetStats($dlx->{Hash}, {active_clients => 1, clients => 1});
				if($dlx->{Range} != $dlx->{Offset}) {
					$self->{super}->Admin->SendNotify("$dlx->{Hash}: Webserver does not support HTTP-Ranges, re-starting download from scratch :-(");
					$dlx->{Storage}->Truncate(0);
					$self->{super}->Queue->SetStats($dlx->{Hash}, {done_bytes => 0 });
				}
				
				last;
			}
		}
	}
	
	if($dlx->{GotHeader} != 0) {
		my $dlen  = length($dlx->{piggy});
		my $ddone = $self->{super}->Queue->GetStats($dlx->{Hash})->{done_bytes};
		my $tdone = $dlen + $ddone;
		my $bleft = $self->{super}->Queue->GetStats($dlx->{Hash})->{total_bytes} - $tdone;
		
		if($bleft < 0) {
			$self->warn("$dlx->{Hash}: $dlx->{Host} sent too much data! ($bleft) ; Closing connection with server!");
			$self->_KillClient($socket);
			return undef;
		}
		
		$dlx->{Storage}->WriteData(Chunk => 0, Offset => $ddone, Length => $dlen, Data => \$dlx->{piggy});
		$self->{super}->Queue->SetStats($dlx->{Hash}, {done_bytes => $tdone});
		delete($dlx->{piggy});
		$dlx->{LastRead} = $self->{super}->Network->GetTime;
		if($bleft == 0) {
			$dlx->{Storage}->SetAsDone(0);
			$self->{super}->Queue->SetStats($dlx->{Hash}, {done_chunks => 1});
		}
	}
}

sub _KillClient {
	my($self,$socket) = @_;
	$self->_Network_Close($socket);
	$self->{super}->Network->RemoveSocket($self, $socket);
	return undef;
}

sub _Pickup {
	my($self) = @_;
	my $NOW = $self->{super}->Network->GetTime;
	$self->{nextpickup} = $NOW+PICKUP_DELAY;
	my $full_q = ();
	my $xql    = $self->{super}->Queue->GetQueueList;
	foreach my $qk (keys(%{$xql->{''.STORAGE_TYPE}}))      { $full_q->{$qk}++       }
	foreach my $qk (keys(%{$self->{dlx}->{get_socket}}))   { delete($full_q->{$qk}) }
	foreach my $qk (keys(%{$self->{dlx}->{has_socket}})) {
		my $dlx = $self->{dlx}->{has_socket}->{$qk};
		if(($dlx->{LastRead}+TIMEOUT_DELAY < $self->{super}->Network->GetTime) ) {
			$self->warn("$dlx->{Hash} : Attemping to re-connect");
			$self->_KillClient($dlx->{Socket});
		}
		else {
			delete($full_q->{$dlx->{Hash}}) or $self->warn("$dlx->{Hash} does not exist in queue but is active, ?!");
		}
	}
	
	foreach my $qk (keys(%$full_q)) {
		my $xso = $self->{super}->Storage->OpenStorage($qk) or $self->panic("Unable to resume $qk");
		next unless $xso->IsSetAsInwork(0);
		$self->info("Resuming incomplete download '$qk'");
		my($xsha,$xactive) = $self->_InitDownload(Host=>$xso->GetSetting('_host'), Port=>$xso->GetSetting('_port'),
		                                          Url=>$xso->GetSetting('_url'), Offset=>$self->{super}->Queue->GetStats($qk)->{done_bytes});
		$self->panic("$xsha != $qk : Unable to resume download $qk ; Recalculate sha1 sum differs") if $xsha ne $qk;
		$self->panic("$qk should be inactive but isn't")                                            if $xactive != 0;
	}
}

sub _Network_Close {
	my($self,$socket) = @_;
	if( (my $dlx = delete($self->{dlx}->{has_socket}->{$socket}) )) {
		$self->{super}->Queue->SetStats($dlx->{Hash}, {active_clients => 0, clients => 0});
	}
	$self->debug("CLOSED $socket");
}






sub debug { my($self, $msg) = @_; $self->{super}->debug(ref($self).": ".$msg); }
sub info  { my($self, $msg) = @_; $self->{super}->info(ref($self).": ".$msg);  }
sub warn  { my($self, $msg) = @_; $self->{super}->warn(ref($self).": ".$msg);  }
sub panic { my($self, $msg) = @_; $self->{super}->panic(ref($self).": ".$msg); }


1;