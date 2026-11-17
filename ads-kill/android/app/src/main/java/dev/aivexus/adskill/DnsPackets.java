package dev.aivexus.adskill;

import java.nio.charset.StandardCharsets;
import java.util.Arrays;
import java.util.Locale;

/** IPv4 UDP/53 only. No redirects, TLS interception, or packet inspection beyond DNS. */
public final class DnsPackets {
    public final byte[] ipPacket;
    public final byte[] query;
    public final String domain;
    public final int endOfQuestion;
    private final int ihl;

    private DnsPackets(byte[] ipPacket, byte[] query, String domain, int endOfQuestion, int ihl) {
        this.ipPacket = ipPacket;
        this.query = query;
        this.domain = domain;
        this.endOfQuestion = endOfQuestion;
        this.ihl = ihl;
    }

    public static DnsPackets decode(byte[] data, int available) {
        if (available < 28 || (data[0] & 0xf0) != 0x40) return null;
        int ihl = (data[0] & 15) * 4;
        if (ihl < 20 || available < ihl + 8 || (data[9] & 0xff) != 17) return null;
        // Ignore fragmented IPv4: this prototype does not reassemble fragments.
        if ((u16(data, 6) & 0x3fff) != 0) return null;
        int ipLength = u16(data, 2);
        if (ipLength > available || ipLength < ihl + 8) return null;
        if (u16(data, ihl + 2) != 53) return null;
        int udpLength = u16(data, ihl + 4);
        if (udpLength < 20 || udpLength > ipLength - ihl) return null;
        byte[] dns = Arrays.copyOfRange(data, ihl + 8, ihl + udpLength);
        if (dns.length < 17 || (dns[2] & 0x80) != 0 || u16(dns, 4) != 1) return null;
        int offset = 12;
        StringBuilder host = new StringBuilder();
        int totalLen = 0;
        while (true) {
            if (offset >= dns.length) return null;
            int count = dns[offset++] & 0xff;
            if (count == 0) break;
            if ((count & 0xc0) != 0 || count > 63 || offset + count > dns.length) return null;
            totalLen += count + 1;
            if (totalLen > 253) return null;
            if (host.length() > 0) host.append('.');
            for (int j = 0; j < count; j++) {
                int b = dns[offset + j] & 0xff;
                if (b < 33 || b > 126) return null;
            }
            host.append(new String(dns, offset, count, StandardCharsets.US_ASCII));
            offset += count;
        }
        if (offset + 4 > dns.length || host.length() == 0) return null;
        return new DnsPackets(Arrays.copyOf(data, ipLength), dns,
                host.toString().toLowerCase(Locale.ROOT), offset + 4, ihl);
    }

    public byte[] blockedResponse() {
        byte[] answer = Arrays.copyOf(query, endOfQuestion);
        answer[2] = (byte) 0x81;
        answer[3] = (byte) 0x83; // NXDOMAIN, recursion available
        // No answer, authority, or additional records; remove query's optional EDNS OPT.
        Arrays.fill(answer, 6, 12, (byte) 0);
        return answer;
    }

    public byte[] packetForResponse(byte[] dnsResponse) {
        if (dnsResponse == null || dnsResponse.length > 4000) return null;
        int n = 20 + 8 + dnsResponse.length;
        byte[] reply = new byte[n];
        reply[0] = 0x45;
        reply[1] = 0;
        put16(reply, 2, n);
        // No IPv4 fragmentation flags, TTL 64, UDP.
        reply[8] = 64;
        reply[9] = 17;
        System.arraycopy(ipPacket, 16, reply, 12, 4); // reply source = request destination
        System.arraycopy(ipPacket, 12, reply, 16, 4); // reply destination = request source
        put16(reply, 10, checksum(reply, 0, 20));
        int udp = 20;
        put16(reply, udp, 53);
        put16(reply, udp + 2, u16(ipPacket, ihl)); // request source UDP port
        put16(reply, udp + 4, 8 + dnsResponse.length);
        // UDP checksum 0 is permitted for IPv4 (not IPv6).
        System.arraycopy(dnsResponse, 0, reply, 28, dnsResponse.length);
        return reply;
    }

    public static int u16(byte[] b, int at) {
        return ((b[at] & 0xff) << 8) | (b[at + 1] & 0xff);
    }

    private static void put16(byte[] b, int at, int v) {
        b[at] = (byte) (v >>> 8);
        b[at + 1] = (byte) v;
    }

    private static int checksum(byte[] bytes, int from, int len) {
        long sum = 0;
        for (int i = from; i < from + len; i += 2) {
            sum += ((bytes[i] & 255) << 8) | (bytes[i + 1] & 255);
        }
        while ((sum >>> 16) != 0) sum = (sum & 0xffff) + (sum >>> 16);
        return (int) (~sum) & 0xffff;
    }
}
