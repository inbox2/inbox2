# DNS through the unbound beside rspamd (rspamd/unbound.conf), never the
# container's resolver: the DNSBLs refuse shared resolvers. One server only;
# a second would get half the queries.
dns {
  nameserver = ["127.0.0.1:5353"];
}
