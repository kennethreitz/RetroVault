#ifndef RVRA_BRIDGE_H
#define RVRA_BRIDGE_H

#include <stddef.h>
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

typedef struct rvra_client rvra_client;

enum {
  RVRA_LOGIN_IDLE = 0,
  RVRA_LOGIN_PENDING = 1,
  RVRA_LOGIN_SUCCEEDED = 2,
  RVRA_LOGIN_FAILED = 3
};

enum {
  RVRA_GAME_IDLE = 0,
  RVRA_GAME_LOADING = 1,
  RVRA_GAME_LOADED = 2,
  RVRA_GAME_UNSUPPORTED = 3,
  RVRA_GAME_FAILED = 4
};

enum {
  RVRA_NOTICE_NONE = 0,
  RVRA_NOTICE_UNLOCK = 1,
  RVRA_NOTICE_MASTERY = 2,
  RVRA_NOTICE_SUBSET = 3,
  RVRA_NOTICE_LEADERBOARD = 4,
  RVRA_NOTICE_PROGRESS = 5,
  RVRA_NOTICE_RESET = 6,
  RVRA_NOTICE_MESSAGE = 7
};

typedef void (*rvra_http_function)(
    void *userdata,
    uint64_t request_id,
    const char *url,
    const char *post_body,
    const char *content_type);

typedef void *(*rvra_memory_data_function)(uint32_t memory_id, void *userdata);
typedef size_t (*rvra_memory_size_function)(uint32_t memory_id, void *userdata);

rvra_client *rvra_create(void);
void rvra_destroy(rvra_client *client);

void rvra_set_product_version(rvra_client *client, const char *version);
void rvra_rcheevos_clause(const rvra_client *client, char *buffer, size_t length);
void rvra_set_user_agent(rvra_client *client, const char *user_agent);
void rvra_user_agent(const rvra_client *client, char *buffer, size_t length);
void rvra_set_hardcore_enabled(rvra_client *client, int enabled);
int rvra_get_hardcore_enabled(const rvra_client *client);
int rvra_can_pause(rvra_client *client);

void rvra_set_http(rvra_client *client, rvra_http_function function, void *userdata);
void rvra_set_memory(
    rvra_client *client,
    rvra_memory_data_function data,
    rvra_memory_size_function size,
    void *userdata);
void rvra_complete_http(
    rvra_client *client,
    uint64_t request_id,
    int http_status,
    const void *body,
    size_t length);

void rvra_begin_login_with_password(
    rvra_client *client,
    const char *username,
    const char *password);
void rvra_begin_login_with_token(
    rvra_client *client,
    const char *username,
    const char *token);
int rvra_login_state(const rvra_client *client);
void rvra_login_error(const rvra_client *client, char *buffer, size_t length);
void rvra_session_token(const rvra_client *client, char *buffer, size_t length);
void rvra_session_username(const rvra_client *client, char *buffer, size_t length);
void rvra_logout(rvra_client *client);

void rvra_begin_load_game(
    rvra_client *client,
    uint32_t console_id,
    const char *path);
int rvra_game_state(const rvra_client *client);
void rvra_game_error(const rvra_client *client, char *buffer, size_t length);
void rvra_game_summary(
    const rvra_client *client,
    int *unlocked,
    int *total,
    int *unlocked_points,
    int *possible_points);
void rvra_rich_presence(rvra_client *client, char *buffer, size_t length);
void rvra_leaderboard_tracker(const rvra_client *client, char *buffer, size_t length);

void rvra_pump(rvra_client *client);
void rvra_frame(rvra_client *client);
void rvra_acknowledge_reset(rvra_client *client);
int rvra_poll_notice(
    rvra_client *client,
    int *kind,
    char *title,
    size_t title_length,
    char *detail,
    size_t detail_length,
    char *badge_url,
    size_t badge_url_length,
    int *points,
    int *hardcore);

#ifdef __cplusplus
}
#endif

#endif
