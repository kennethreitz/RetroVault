#include "rvra_bridge.h"

#define RC_CLIENT_SUPPORTS_HASH 1

#include "rc_client.h"
#include "rc_libretro.h"

#include <pthread.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#define RVRA_MAX_REQUESTS 8
#define RVRA_MAX_NOTICES 24
#define RVRA_MAX_BODY (2 * 1024 * 1024)

typedef struct rvra_notice {
  int kind;
  char title[192];
  char detail[384];
  char badge_url[384];
  int points;
  int hardcore;
} rvra_notice;

typedef struct rvra_http_slot {
  int active;
  uint64_t id;
  rc_client_server_callback_t callback;
  void *callback_data;
} rvra_http_slot;

typedef struct rvra_http_result {
  int ready;
  uint64_t id;
  int status;
  char *body;
  size_t length;
} rvra_http_result;

struct rvra_client {
  rc_client_t *client;
  rc_libretro_memory_regions_t memory;
  uint32_t console_id;
  int memory_ready;
  int hardcore;

  rvra_http_function http;
  void *http_userdata;
  rvra_memory_data_function memory_data;
  rvra_memory_size_function memory_size;
  void *memory_userdata;

  pthread_mutex_t lock;
  uint64_t next_request_id;
  rvra_http_slot slots[RVRA_MAX_REQUESTS];
  rvra_http_result results[RVRA_MAX_REQUESTS];

  pthread_mutex_t notice_lock;
  rvra_notice notices[RVRA_MAX_NOTICES];
  int notice_head;
  int notice_count;

  int login_state;
  int login_result;
  char login_error[256];
  char token[128];
  char username[64];

  int game_state;
  char game_error[256];
  char user_agent[160];
  char rich_presence[256];
  char leaderboard[96];
};

static void rvra_core_memory_info(uint32_t id, rc_libretro_core_memory_info_t *info);

static void rvra_copy(char *destination, size_t length, const char *source) {
  if (length == 0) {
    return;
  }
  if (source == NULL) {
    destination[0] = '\0';
    return;
  }
  snprintf(destination, length, "%s", source);
}

static void rvra_push_notice(rvra_client *client, const rvra_notice *notice) {
  pthread_mutex_lock(&client->notice_lock);
  if (client->notice_count == RVRA_MAX_NOTICES) {
    client->notice_head = (client->notice_head + 1) % RVRA_MAX_NOTICES;
    client->notice_count -= 1;
  }
  int index = (client->notice_head + client->notice_count) % RVRA_MAX_NOTICES;
  client->notices[index] = *notice;
  client->notice_count += 1;
  pthread_mutex_unlock(&client->notice_lock);
}

static void rvra_notice_message(rvra_client *client, int kind, const char *title, const char *detail) {
  rvra_notice notice;
  memset(&notice, 0, sizeof(notice));
  notice.kind = kind;
  notice.hardcore = client->hardcore;
  rvra_copy(notice.title, sizeof(notice.title), title);
  rvra_copy(notice.detail, sizeof(notice.detail), detail);
  rvra_push_notice(client, &notice);
}

static void rvra_refresh_memory(rvra_client *client) {
  if (client->console_id == 0 || client->memory_data == NULL || client->memory_size == NULL) {
    return;
  }
  rc_libretro_memory_destroy(&client->memory);
  rc_libretro_memory_init(
      &client->memory,
      NULL,
      rvra_core_memory_info,
      client->console_id);
  client->memory_ready = 1;
}

static _Thread_local rvra_client *rvra_tls_client = NULL;

static void rvra_core_memory_info(uint32_t id, rc_libretro_core_memory_info_t *info) {
  rvra_client *client = rvra_tls_client;
  info->data = NULL;
  info->size = 0;
  if (client == NULL || client->memory_data == NULL || client->memory_size == NULL) {
    return;
  }
  info->data = client->memory_data(id, client->memory_userdata);
  info->size = client->memory_size(id, client->memory_userdata);
}

static uint32_t rvra_read_memory(
    uint32_t address,
    uint8_t *buffer,
    uint32_t num_bytes,
    rc_client_t *rc_client) {
  rvra_client *client = rc_client_get_userdata(rc_client);
  if (client == NULL || !client->memory_ready) {
    return 0;
  }
  return rc_libretro_memory_read(&client->memory, address, buffer, num_bytes);
}

static void rvra_server_call(
    const rc_api_request_t *request,
    rc_client_server_callback_t callback,
    void *callback_data,
    rc_client_t *rc_client) {
  rvra_client *client = rc_client_get_userdata(rc_client);
  if (client == NULL || request == NULL || request->url == NULL) {
    rc_api_server_response_t response = {0};
    response.http_status_code = RC_API_SERVER_RESPONSE_CLIENT_ERROR;
    callback(&response, callback_data);
    return;
  }

  pthread_mutex_lock(&client->lock);
  rvra_http_slot *slot = NULL;
  for (int index = 0; index < RVRA_MAX_REQUESTS; index += 1) {
    if (!client->slots[index].active) {
      slot = &client->slots[index];
      break;
    }
  }
  if (slot == NULL) {
    pthread_mutex_unlock(&client->lock);
    rc_api_server_response_t response = {0};
    response.http_status_code = RC_API_SERVER_RESPONSE_CLIENT_ERROR;
    callback(&response, callback_data);
    return;
  }

  uint64_t request_id = client->next_request_id++;
  slot->active = 1;
  slot->id = request_id;
  slot->callback = callback;
  slot->callback_data = callback_data;
  char *url = strdup(request->url);
  char *post = request->post_data == NULL ? NULL : strdup(request->post_data);
  char *content_type = request->content_type == NULL ? NULL : strdup(request->content_type);
  rvra_http_function http = client->http;
  void *userdata = client->http_userdata;
  pthread_mutex_unlock(&client->lock);

  if (url == NULL || http == NULL) {
    free(url);
    free(post);
    free(content_type);
    rvra_complete_http(client, request_id, RC_API_SERVER_RESPONSE_CLIENT_ERROR, NULL, 0);
    return;
  }

  http(userdata, request_id, url, post, content_type);
  free(url);
  free(post);
  free(content_type);
}

static void rvra_apply_user(rvra_client *client) {
  const rc_client_user_t *user = rc_client_get_user_info(client->client);
  if (user == NULL) {
    return;
  }
  rvra_copy(client->username, sizeof(client->username), user->username);
  rvra_copy(client->token, sizeof(client->token), user->token);
}

static void rvra_login_callback(int result, const char *error_message, rc_client_t *rc_client, void *userdata) {
  rvra_client *client = userdata;
  if (client == NULL) {
    return;
  }
  if (result == RC_OK) {
    client->login_state = RVRA_LOGIN_SUCCEEDED;
    client->login_result = RC_OK;
    client->login_error[0] = '\0';
    rvra_apply_user(client);
    return;
  }
  client->login_state = RVRA_LOGIN_FAILED;
  client->login_result = result;
  rvra_copy(
      client->login_error,
      sizeof(client->login_error),
      error_message == NULL ? "RetroAchievements did not accept the sign-in." : error_message);
  client->token[0] = '\0';
}

static void rvra_load_callback(int result, const char *error_message, rc_client_t *rc_client, void *userdata) {
  rvra_client *client = userdata;
  if (client == NULL) {
    return;
  }
  if (result == RC_OK && rc_client_is_game_loaded(client->client)) {
    client->game_state = RVRA_GAME_LOADED;
    client->game_error[0] = '\0';
    return;
  }
  if (result == RC_NO_GAME_LOADED || result == RC_NOT_FOUND || result == RC_OK) {
    client->game_state = RVRA_GAME_UNSUPPORTED;
    client->game_error[0] = '\0';
    return;
  }
  client->game_state = RVRA_GAME_FAILED;
  rvra_copy(
      client->game_error,
      sizeof(client->game_error),
      error_message == NULL ? "RetroAchievements could not load this game." : error_message);
}

static void rvra_badge_url(const rc_client_achievement_t *achievement, char *buffer, size_t length) {
  buffer[0] = '\0';
  if (achievement == NULL) {
    return;
  }
  if (rc_client_achievement_get_image_url(
          achievement,
          RC_CLIENT_ACHIEVEMENT_STATE_UNLOCKED,
          buffer,
          length) != RC_OK) {
    buffer[0] = '\0';
  }
}

static void rvra_event(const rc_client_event_t *event, rc_client_t *rc_client) {
  rvra_client *client = rc_client_get_userdata(rc_client);
  if (client == NULL || event == NULL) {
    return;
  }

  switch (event->type) {
    case RC_CLIENT_EVENT_ACHIEVEMENT_TRIGGERED: {
      rvra_notice notice;
      memset(&notice, 0, sizeof(notice));
      notice.kind = RVRA_NOTICE_UNLOCK;
      notice.hardcore = client->hardcore;
      if (event->achievement != NULL) {
        rvra_copy(notice.title, sizeof(notice.title), event->achievement->title);
        rvra_copy(notice.detail, sizeof(notice.detail), event->achievement->description);
        notice.points = (int)event->achievement->points;
        rvra_badge_url(event->achievement, notice.badge_url, sizeof(notice.badge_url));
      }
      rvra_push_notice(client, &notice);
      break;
    }
    case RC_CLIENT_EVENT_GAME_COMPLETED: {
      const rc_client_game_t *game = rc_client_get_game_info(client->client);
      rvra_notice notice;
      memset(&notice, 0, sizeof(notice));
      notice.kind = RVRA_NOTICE_MASTERY;
      notice.hardcore = client->hardcore;
      rvra_copy(notice.title, sizeof(notice.title), game == NULL ? "Game complete" : game->title);
      rvra_copy(
          notice.detail,
          sizeof(notice.detail),
          client->hardcore
              ? "Every achievement in this set was earned in Hardcore mode."
              : "Every achievement in this set was earned.");
      if (game != NULL && game->badge_url != NULL) {
        rvra_copy(notice.badge_url, sizeof(notice.badge_url), game->badge_url);
      }
      rvra_push_notice(client, &notice);
      break;
    }
    case RC_CLIENT_EVENT_SUBSET_COMPLETED: {
      rvra_notice notice;
      memset(&notice, 0, sizeof(notice));
      notice.kind = RVRA_NOTICE_SUBSET;
      notice.hardcore = client->hardcore;
      rvra_copy(
          notice.title,
          sizeof(notice.title),
          event->subset == NULL ? "Subset complete" : event->subset->title);
      rvra_copy(notice.detail, sizeof(notice.detail), "Every achievement in this subset was earned.");
      rvra_push_notice(client, &notice);
      break;
    }
    case RC_CLIENT_EVENT_LEADERBOARD_STARTED:
    case RC_CLIENT_EVENT_LEADERBOARD_FAILED:
    case RC_CLIENT_EVENT_LEADERBOARD_SUBMITTED: {
      rvra_notice notice;
      memset(&notice, 0, sizeof(notice));
      notice.kind = RVRA_NOTICE_LEADERBOARD;
      notice.hardcore = client->hardcore;
      const char *title = event->leaderboard == NULL ? "Leaderboard" : event->leaderboard->title;
      rvra_copy(notice.title, sizeof(notice.title), title);
      const char *detail = "Leaderboard updated.";
      if (event->type == RC_CLIENT_EVENT_LEADERBOARD_STARTED) {
        detail = "Attempt started.";
      } else if (event->type == RC_CLIENT_EVENT_LEADERBOARD_FAILED) {
        detail = "Attempt failed.";
      } else if (event->type == RC_CLIENT_EVENT_LEADERBOARD_SUBMITTED) {
        detail = "Score submitted.";
      }
      rvra_copy(notice.detail, sizeof(notice.detail), detail);
      rvra_push_notice(client, &notice);
      break;
    }
    case RC_CLIENT_EVENT_LEADERBOARD_TRACKER_SHOW:
    case RC_CLIENT_EVENT_LEADERBOARD_TRACKER_UPDATE:
      if (event->leaderboard_tracker != NULL) {
        rvra_copy(client->leaderboard, sizeof(client->leaderboard), event->leaderboard_tracker->display);
      }
      break;
    case RC_CLIENT_EVENT_LEADERBOARD_TRACKER_HIDE:
      client->leaderboard[0] = '\0';
      break;
    case RC_CLIENT_EVENT_ACHIEVEMENT_PROGRESS_INDICATOR_SHOW:
    case RC_CLIENT_EVENT_ACHIEVEMENT_PROGRESS_INDICATOR_UPDATE: {
      rvra_notice notice;
      memset(&notice, 0, sizeof(notice));
      notice.kind = RVRA_NOTICE_PROGRESS;
      if (event->achievement != NULL) {
        rvra_copy(notice.title, sizeof(notice.title), event->achievement->title);
        rvra_copy(notice.detail, sizeof(notice.detail), event->achievement->measured_progress);
        rvra_badge_url(event->achievement, notice.badge_url, sizeof(notice.badge_url));
      }
      rvra_push_notice(client, &notice);
      break;
    }
    case RC_CLIENT_EVENT_ACHIEVEMENT_PROGRESS_INDICATOR_HIDE:
      break;
    case RC_CLIENT_EVENT_RESET:
      rvra_notice_message(client, RVRA_NOTICE_RESET, "Reset", "Hardcore mode reset the game.");
      break;
    case RC_CLIENT_EVENT_SERVER_ERROR:
      if (event->server_error != NULL && event->server_error->error_message != NULL) {
        rvra_notice_message(client, RVRA_NOTICE_MESSAGE, "RetroAchievements", event->server_error->error_message);
      }
      break;
    case RC_CLIENT_EVENT_DISCONNECTED:
      rvra_notice_message(
          client,
          RVRA_NOTICE_MESSAGE,
          "RetroAchievements",
          "An unlock is waiting for a connection.");
      break;
    case RC_CLIENT_EVENT_RECONNECTED:
      rvra_notice_message(client, RVRA_NOTICE_MESSAGE, "RetroAchievements", "Pending unlocks were submitted.");
      break;
    default:
      break;
  }
}

static void rvra_drain_http(rvra_client *client) {
  for (;;) {
    rc_client_server_callback_t callback = NULL;
    void *callback_data = NULL;
    int status = 0;
    char *body = NULL;
    size_t length = 0;

    pthread_mutex_lock(&client->lock);
    int found = 0;
    for (int index = 0; index < RVRA_MAX_REQUESTS; index += 1) {
      if (!client->results[index].ready) {
        continue;
      }
      uint64_t id = client->results[index].id;
      for (int slot = 0; slot < RVRA_MAX_REQUESTS; slot += 1) {
        if (client->slots[slot].active && client->slots[slot].id == id) {
          callback = client->slots[slot].callback;
          callback_data = client->slots[slot].callback_data;
          client->slots[slot].active = 0;
          break;
        }
      }
      status = client->results[index].status;
      body = client->results[index].body;
      length = client->results[index].length;
      client->results[index].ready = 0;
      client->results[index].body = NULL;
      found = 1;
      break;
    }
    pthread_mutex_unlock(&client->lock);

    if (!found) {
      break;
    }
    if (callback != NULL) {
      rc_api_server_response_t response = {0};
      response.body = body;
      response.body_length = length;
      response.http_status_code = status;
      callback(&response, callback_data);
    }
    free(body);
  }
}

rvra_client *rvra_create(void) {
  rvra_client *client = calloc(1, sizeof(*client));
  if (client == NULL) {
    return NULL;
  }
  pthread_mutex_init(&client->lock, NULL);
  pthread_mutex_init(&client->notice_lock, NULL);
  client->next_request_id = 1;
  client->client = rc_client_create(rvra_read_memory, rvra_server_call);
  if (client->client == NULL) {
    rvra_destroy(client);
    return NULL;
  }
  rc_client_set_userdata(client->client, client);
  rc_client_set_event_handler(client->client, rvra_event);
  rc_client_set_hardcore_enabled(client->client, 0);
  rc_client_set_allow_background_memory_reads(client->client, 0);
  rc_client_set_host(client->client, "https://retroachievements.org");
  rvra_copy(client->user_agent, sizeof(client->user_agent), "RetroVault");
  return client;
}

void rvra_destroy(rvra_client *client) {
  if (client == NULL) {
    return;
  }
  if (client->client != NULL) {
    rc_client_destroy(client->client);
  }
  rc_libretro_memory_destroy(&client->memory);
  for (int index = 0; index < RVRA_MAX_REQUESTS; index += 1) {
    free(client->results[index].body);
  }
  pthread_mutex_destroy(&client->lock);
  pthread_mutex_destroy(&client->notice_lock);
  free(client);
}

void rvra_set_product_version(rvra_client *client, const char *version) {
  if (client == NULL) {
    return;
  }
  char clause[80];
  clause[0] = '\0';
  rc_client_get_user_agent_clause(client->client, clause, sizeof(clause));
  if (version == NULL || version[0] == '\0') {
    version = "0";
  }
  snprintf(client->user_agent, sizeof(client->user_agent), "RetroVault/%s %s", version, clause);
}

void rvra_rcheevos_clause(const rvra_client *client, char *buffer, size_t length) {
  if (buffer == NULL || length == 0) {
    return;
  }
  buffer[0] = '\0';
  if (client == NULL) {
    return;
  }
  rc_client_get_user_agent_clause(client->client, buffer, length);
}

void rvra_set_user_agent(rvra_client *client, const char *user_agent) {
  if (client == NULL) {
    return;
  }
  rvra_copy(client->user_agent, sizeof(client->user_agent), user_agent);
}

void rvra_user_agent(const rvra_client *client, char *buffer, size_t length) {
  if (buffer == NULL || length == 0) {
    return;
  }
  rvra_copy(buffer, length, client == NULL ? "RetroVault" : client->user_agent);
}

void rvra_set_hardcore_enabled(rvra_client *client, int enabled) {
  if (client == NULL) {
    return;
  }
  client->hardcore = enabled ? 1 : 0;
  rc_client_set_hardcore_enabled(client->client, client->hardcore);
}

int rvra_get_hardcore_enabled(const rvra_client *client) {
  return client != NULL && rc_client_get_hardcore_enabled(client->client);
}

int rvra_can_pause(rvra_client *client) {
  if (client == NULL || !client->hardcore) {
    return 1;
  }
  return rc_client_can_pause(client->client, NULL);
}

void rvra_set_http(rvra_client *client, rvra_http_function function, void *userdata) {
  if (client == NULL) {
    return;
  }
  pthread_mutex_lock(&client->lock);
  client->http = function;
  client->http_userdata = userdata;
  pthread_mutex_unlock(&client->lock);
}

void rvra_set_memory(
    rvra_client *client,
    rvra_memory_data_function data,
    rvra_memory_size_function size,
    void *userdata) {
  if (client == NULL) {
    return;
  }
  client->memory_data = data;
  client->memory_size = size;
  client->memory_userdata = userdata;
}

void rvra_complete_http(
    rvra_client *client,
    uint64_t request_id,
    int http_status,
    const void *body,
    size_t length) {
  if (client == NULL) {
    return;
  }
  if (length > RVRA_MAX_BODY) {
    body = NULL;
    length = 0;
    http_status = RC_API_SERVER_RESPONSE_CLIENT_ERROR;
  }
  char *copy = NULL;
  if (body != NULL && length > 0) {
    copy = malloc(length + 1);
    if (copy == NULL) {
      http_status = RC_API_SERVER_RESPONSE_CLIENT_ERROR;
      length = 0;
    } else {
      memcpy(copy, body, length);
      copy[length] = '\0';
    }
  }

  pthread_mutex_lock(&client->lock);
  int stored = 0;
  for (int index = 0; index < RVRA_MAX_REQUESTS; index += 1) {
    if (client->results[index].ready) {
      continue;
    }
    client->results[index].ready = 1;
    client->results[index].id = request_id;
    client->results[index].status = http_status;
    client->results[index].body = copy;
    client->results[index].length = copy == NULL ? 0 : length;
    stored = 1;
    break;
  }
  pthread_mutex_unlock(&client->lock);
  if (!stored) {
    free(copy);
  }
}

void rvra_begin_login_with_password(
    rvra_client *client,
    const char *username,
    const char *password) {
  if (client == NULL) {
    return;
  }
  client->login_state = RVRA_LOGIN_PENDING;
  client->login_error[0] = '\0';
  client->token[0] = '\0';
  rc_client_begin_login_with_password(
      client->client,
      username == NULL ? "" : username,
      password == NULL ? "" : password,
      rvra_login_callback,
      client);
}

void rvra_begin_login_with_token(
    rvra_client *client,
    const char *username,
    const char *token) {
  if (client == NULL) {
    return;
  }
  client->login_state = RVRA_LOGIN_PENDING;
  client->login_error[0] = '\0';
  rc_client_begin_login_with_token(
      client->client,
      username == NULL ? "" : username,
      token == NULL ? "" : token,
      rvra_login_callback,
      client);
}

int rvra_login_state(const rvra_client *client) {
  return client == NULL ? RVRA_LOGIN_IDLE : client->login_state;
}

void rvra_login_error(const rvra_client *client, char *buffer, size_t length) {
  rvra_copy(buffer, length, client == NULL ? NULL : client->login_error);
}

void rvra_session_token(const rvra_client *client, char *buffer, size_t length) {
  rvra_copy(buffer, length, client == NULL ? NULL : client->token);
}

void rvra_session_username(const rvra_client *client, char *buffer, size_t length) {
  rvra_copy(buffer, length, client == NULL ? NULL : client->username);
}

void rvra_logout(rvra_client *client) {
  if (client == NULL) {
    return;
  }
  rc_client_logout(client->client);
  client->login_state = RVRA_LOGIN_IDLE;
  client->token[0] = '\0';
  client->username[0] = '\0';
}

void rvra_begin_load_game(rvra_client *client, uint32_t console_id, const char *path) {
  if (client == NULL) {
    return;
  }
  client->console_id = console_id;
  client->game_state = RVRA_GAME_LOADING;
  client->game_error[0] = '\0';
  rvra_tls_client = client;
  rvra_refresh_memory(client);
  rvra_tls_client = NULL;
  rc_client_begin_identify_and_load_game(
      client->client,
      console_id,
      path,
      NULL,
      0,
      rvra_load_callback,
      client);
}

int rvra_game_state(const rvra_client *client) {
  return client == NULL ? RVRA_GAME_IDLE : client->game_state;
}

void rvra_game_error(const rvra_client *client, char *buffer, size_t length) {
  rvra_copy(buffer, length, client == NULL ? NULL : client->game_error);
}

void rvra_game_summary(
    const rvra_client *client,
    int *unlocked,
    int *total,
    int *unlocked_points,
    int *possible_points) {
  rc_client_user_game_summary_t summary;
  memset(&summary, 0, sizeof(summary));
  if (client != NULL && client->game_state == RVRA_GAME_LOADED) {
    rc_client_get_user_game_summary(client->client, &summary);
  }
  if (unlocked != NULL) {
    *unlocked = (int)summary.num_unlocked_achievements;
  }
  if (total != NULL) {
    *total = (int)summary.num_core_achievements;
  }
  if (unlocked_points != NULL) {
    *unlocked_points = (int)summary.points_unlocked;
  }
  if (possible_points != NULL) {
    *possible_points = (int)summary.points_core;
  }
}

void rvra_rich_presence(rvra_client *client, char *buffer, size_t length) {
  if (buffer == NULL || length == 0) {
    return;
  }
  buffer[0] = '\0';
  if (client == NULL || !rc_client_has_rich_presence(client->client)) {
    return;
  }
  rc_client_get_rich_presence_message(client->client, buffer, length);
}

void rvra_leaderboard_tracker(const rvra_client *client, char *buffer, size_t length) {
  rvra_copy(buffer, length, client == NULL ? NULL : client->leaderboard);
}

void rvra_pump(rvra_client *client) {
  if (client == NULL) {
    return;
  }
  rvra_drain_http(client);
  rc_client_idle(client->client);
}

void rvra_frame(rvra_client *client) {
  if (client == NULL) {
    return;
  }
  rvra_tls_client = client;
  rvra_refresh_memory(client);
  rvra_drain_http(client);
  rc_client_do_frame(client->client);
  if (rc_client_has_rich_presence(client->client)) {
    rc_client_get_rich_presence_message(
        client->client,
        client->rich_presence,
        sizeof(client->rich_presence));
  }
  rvra_tls_client = NULL;
}

void rvra_acknowledge_reset(rvra_client *client) {
  if (client == NULL) {
    return;
  }
  rc_client_reset(client->client);
}

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
    int *hardcore) {
  if (client == NULL) {
    return 0;
  }
  pthread_mutex_lock(&client->notice_lock);
  if (client->notice_count == 0) {
    pthread_mutex_unlock(&client->notice_lock);
    return 0;
  }
  rvra_notice notice = client->notices[client->notice_head];
  client->notice_head = (client->notice_head + 1) % RVRA_MAX_NOTICES;
  client->notice_count -= 1;
  pthread_mutex_unlock(&client->notice_lock);
  if (kind != NULL) {
    *kind = notice.kind;
  }
  rvra_copy(title, title_length, notice.title);
  rvra_copy(detail, detail_length, notice.detail);
  rvra_copy(badge_url, badge_url_length, notice.badge_url);
  if (points != NULL) {
    *points = notice.points;
  }
  if (hardcore != NULL) {
    *hardcore = notice.hardcore;
  }
  return 1;
}
