/*
 * Long-lived TCP client bound to LOCAL_IP for R30 local CRIU smoke.
 * Usage: workload_tcp <state_path> <counter_path>
 */
#include <arpa/inet.h>
#include <netinet/in.h>
#include <stdio.h>
#include <string.h>
#include <unistd.h>

int main(int argc, char *argv[]) {
    const char *state_path = argc > 1 ? argv[1] : "/tmp/r30_tcp_status.txt";
    const char *counter_path = argc > 2 ? argv[2] : "/tmp/r30_tcp_counter.txt";

    int sock = socket(AF_INET, SOCK_STREAM, 0);
    if (sock < 0) {
        perror("socket");
        return 1;
    }
    int reuse = 1;
    setsockopt(sock, SOL_SOCKET, SO_REUSEADDR, &reuse, sizeof(reuse));

    struct sockaddr_in local_addr;
    memset(&local_addr, 0, sizeof(local_addr));
    local_addr.sin_family = AF_INET;
    inet_pton(AF_INET, "10.200.1.2", &local_addr.sin_addr);
    local_addr.sin_port = htons(45678);

    if (bind(sock, (struct sockaddr *)&local_addr, sizeof(local_addr)) < 0) {
        perror("bind");
        return 2;
    }

    struct sockaddr_in peer_addr;
    memset(&peer_addr, 0, sizeof(peer_addr));
    peer_addr.sin_family = AF_INET;
    inet_pton(AF_INET, "10.200.0.1", &peer_addr.sin_addr);
    peer_addr.sin_port = htons(19876);

    if (connect(sock, (struct sockaddr *)&peer_addr, sizeof(peer_addr)) < 0) {
        perror("connect");
        return 3;
    }

    send(sock, "HELLO\n", 6, 0);
    char buf[256];
    int n = recv(sock, buf, sizeof(buf) - 1, 0);
    if (n <= 0) {
        perror("recv");
        return 4;
    }
    buf[n] = '\0';

    FILE *f = fopen(state_path, "w");
    if (f) {
        fprintf(f, "INITIAL_CONNECTED\n");
        fclose(f);
    }

    int counter = 100;
    f = fopen(counter_path, "w");
    if (f) {
        fprintf(f, "%d\n", counter);
        fclose(f);
    }

    while (1) {
        n = recv(sock, buf, sizeof(buf) - 1, 0);
        if (n <= 0)
            break;
        buf[n] = '\0';

        if (strncmp(buf, "PING", 4) == 0) {
            counter++;
            char pong[128];
            snprintf(pong, sizeof(pong), "PONG %d\n", counter);
            send(sock, pong, (size_t)strlen(pong), 0);
            f = fopen(counter_path, "w");
            if (f) {
                fprintf(f, "%d\n", counter);
                fclose(f);
            }
        } else if (strncmp(buf, "FINISH", 6) == 0) {
            f = fopen(counter_path, "w");
            if (f) {
                fprintf(f, "TCP_MIGRATION_VERIFIED final_counter=%d\n", counter);
                fclose(f);
            }
            send(sock, "ACK_FINISH\n", 11, 0);
            break;
        }
    }

    close(sock);
    return 0;
}
