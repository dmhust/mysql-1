/* Copyright (C) 2007 Google Inc.
   Copyright (C) 2008 MySQL AB

   This program is free software; you can redistribute it and/or modify
   it under the terms of the GNU General Public License as published by
   the Free Software Foundation; version 2 of the License.

   This program is distributed in the hope that it will be useful,
   but WITHOUT ANY WARRANTY; without even the implied warranty of
   MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
   GNU General Public License for more details.

   You should have received a copy of the GNU General Public License
   along with this program; if not, write to the Free Software
   Foundation, Inc., 51 Franklin St, Fifth Floor, Boston, MA  02110-1301  USA */


#include "semisync_master.h"

ReplSemiSyncMaster repl_semisync;

int repl_semi_report_binlog_update(Binlog_storage_param *param,
				   const char *log_file,
				   my_off_t log_pos, uint32 flags)
{
  int  error= 0;

  if (repl_semisync.getMasterEnabled())
  {
    /*
      Let us store the binlog file name and the position, so that
      we know how long to wait for the binlog to the replicated to
      the slave in synchronous replication.
    */
    error= repl_semisync.writeTranxInBinlog(log_file,
                                            log_pos);
  }

  return error;
}

int repl_semi_request_commit(Trans_param *param)
{
  return 0;
}

int repl_semi_report_commit(Trans_param *param)
{

  bool is_real_trans= param->flags & TRANS_IS_REAL_TRANS;

  if (is_real_trans && param->log_pos)
  {
    const char *binlog_name= param->log_file;
    return repl_semisync.commitTrx(binlog_name, param->log_pos);
  }
  return 0;
}

int repl_semi_report_rollback(Trans_param *param)
{
  return repl_semi_report_commit(param);
}

int repl_semi_binlog_dump_start(Binlog_transmit_param *param,
				 const char *log_file,
				 my_off_t log_pos)
{
  bool semi_sync_slave= repl_semisync.is_semi_sync_slave();
  
  if (semi_sync_slave)
    /* One more semi-sync slave */
    repl_semisync.add_slave();
  sql_print_information("Start %s binlog_dump to slave (server_id: %d), pos(%s, %lu)",
			semi_sync_slave ? "semi-sync" : "asynchronous",
			param->server_id, log_file, (unsigned long)log_pos);
  
  return 0;
}

int repl_semi_binlog_dump_end(Binlog_transmit_param *param)
{
  bool semi_sync_slave= repl_semisync.is_semi_sync_slave();
  
  sql_print_information("Stop %s binlog_dump to slave (server_id: %d)",
                        semi_sync_slave ? "semi-sync" : "asynchronous",
                        param->server_id);
  if (semi_sync_slave)
  {
    /* One less semi-sync slave */
    repl_semisync.remove_slave();
  }
  return 0;
}

int repl_semi_reserve_header(Binlog_transmit_param *param,
			     unsigned char *header,
			     unsigned long size, unsigned long *len)
{
  *len +=  repl_semisync.reserveSyncHeader(header, size);
  return 0;
}

int repl_semi_before_send_event(Binlog_transmit_param *param,
                                unsigned char *packet, unsigned long len,
                                const char *log_file, my_off_t log_pos)
{
  return repl_semisync.updateSyncHeader(packet,
					log_file,
					log_pos,
					param->server_id);
}

int repl_semi_after_send_event(Binlog_transmit_param *param,
                               const char *event_buf, unsigned long len)
{
  return 0;
}

int repl_semi_reset_master(Binlog_transmit_param *param)
{
  if (repl_semisync.resetMaster())
    return 1;
  return 0;
}

/*
  semisync system variables
 */
static void fix_rpl_semi_sync_master_timeout(MYSQL_THD thd,
				      SYS_VAR *var,
				      void *ptr,
				      const void *val);

static void fix_rpl_semi_sync_master_trace_level(MYSQL_THD thd,
					  SYS_VAR *var,
					  void *ptr,
					  const void *val);

static void fix_rpl_semi_sync_master_enabled(MYSQL_THD thd,
				      SYS_VAR *var,
				      void *ptr,
				      const void *val);

static void fix_rpl_semi_sync_master_reply_log_file_pos(MYSQL_THD thd,
                                                 SYS_VAR *var,
                                                 void *ptr,
                                                 const void *val);

static MYSQL_SYSVAR_BOOL(enabled, rpl_semi_sync_master_enabled,
  PLUGIN_VAR_OPCMDARG,
 "Enable semi-synchronous replication master (disabled by default). ",
  NULL, 			// check
  &fix_rpl_semi_sync_master_enabled,	// update
  0);

static MYSQL_SYSVAR_ULONG(timeout, rpl_semi_sync_master_timeout,
  PLUGIN_VAR_OPCMDARG,
 "The timeout value (in ms) for semi-synchronous replication in the master",
  NULL, 			// check
  fix_rpl_semi_sync_master_timeout,	// update
  10000, 0, ~0L, 1);

static MYSQL_SYSVAR_ULONG(trace_level, rpl_semi_sync_master_trace_level,
  PLUGIN_VAR_OPCMDARG,
 "The tracing level for semi-sync replication.",
  NULL,				  // check
  &fix_rpl_semi_sync_master_trace_level, // update
  32, 0, ~0L, 1);

/*
  Use a SESSION instead of GLOBAL variable for slave to send reply to
  avoid requiring SUPER privilege.
*/
static MYSQL_THDVAR_STR(reply_log_file_pos,
  PLUGIN_VAR_NOCMDOPT,
  "The log filename and position slave has queued to relay log.",
  NULL,             // check
  &fix_rpl_semi_sync_master_reply_log_file_pos,
  "");

static SYS_VAR* semi_sync_master_system_vars[]= {
  MYSQL_SYSVAR(enabled),
  MYSQL_SYSVAR(timeout),
  MYSQL_SYSVAR(trace_level),
  MYSQL_SYSVAR(reply_log_file_pos),
  NULL,
};


static void fix_rpl_semi_sync_master_timeout(MYSQL_THD thd,
				      SYS_VAR *var,
				      void *ptr,
				      const void *val)
{
  *(unsigned long *)ptr= *(unsigned long *)val;
  repl_semisync.setWaitTimeout(rpl_semi_sync_master_timeout);
  return;
}

static void fix_rpl_semi_sync_master_trace_level(MYSQL_THD thd,
					  SYS_VAR *var,
					  void *ptr,
					  const void *val)
{
  *(unsigned long *)ptr= *(unsigned long *)val;
  repl_semisync.setTraceLevel(rpl_semi_sync_master_trace_level);
  return;
}

static void fix_rpl_semi_sync_master_enabled(MYSQL_THD thd,
				      SYS_VAR *var,
				      void *ptr,
				      const void *val)
{
  *(char *)ptr= *(char *)val;
  if (rpl_semi_sync_master_enabled)
  {
    if (repl_semisync.enableMaster() != 0)
      rpl_semi_sync_master_enabled = false;
  }
  else
  {
    if (repl_semisync.disableMaster() != 0)
      rpl_semi_sync_master_enabled = true;
  }

  return;
}

static void fix_rpl_semi_sync_master_reply_log_file_pos(MYSQL_THD thd,
                                                 SYS_VAR *var,
                                                 void *ptr,
                                                 const void *val)
{
  const char *log_file_pos= *(char **)val;
  
  if (repl_semisync.reportReplyBinlog(log_file_pos))
    sql_print_error("report slave binlog reply failed.");

  return;
}

Trans_observer trans_observer = {
  sizeof(Trans_observer),		// len

  repl_semi_report_commit,	// after_commit
  repl_semi_report_rollback,	// after_rollback
};

Binlog_storage_observer storage_observer = {
  sizeof(Binlog_storage_observer), // len

  repl_semi_report_binlog_update, // report_update
};

Binlog_transmit_observer transmit_observer = {
  sizeof(Binlog_transmit_observer), // len

  repl_semi_binlog_dump_start,	// start
  repl_semi_binlog_dump_end,	// stop
  repl_semi_reserve_header,	// reserve_header
  repl_semi_before_send_event,	// before_send_event
  repl_semi_after_send_event,	// after_send_event
  repl_semi_reset_master,	// reset
};


#define SHOW_FNAME(name)			\
  rpl_semi_sync_master_show_##name

#define DEF_SHOW_FUNC(name, show_type)					\
  static  int SHOW_FNAME(name)(MYSQL_THD thd, SHOW_VAR *var, char *buff) \
  {									\
    repl_semisync.setExportStats();					\
    var->type= show_type;						\
    var->value= (char *)&rpl_semi_sync_master_##name;				\
    return 0;								\
  }

DEF_SHOW_FUNC(clients, SHOW_LONG)
DEF_SHOW_FUNC(net_wait_time, SHOW_LONG)
DEF_SHOW_FUNC(net_wait_total_time, SHOW_LONGLONG)
DEF_SHOW_FUNC(net_wait_num, SHOW_LONGLONG)
DEF_SHOW_FUNC(off_times, SHOW_LONG)
DEF_SHOW_FUNC(no_transactions, SHOW_LONG)
DEF_SHOW_FUNC(status, SHOW_BOOL)
DEF_SHOW_FUNC(timefunc_fails, SHOW_LONG)
DEF_SHOW_FUNC(trx_wait_time, SHOW_LONG)
DEF_SHOW_FUNC(trx_wait_total_time, SHOW_LONGLONG)
DEF_SHOW_FUNC(trx_wait_num, SHOW_LONGLONG)
DEF_SHOW_FUNC(back_wait_pos, SHOW_LONG)
DEF_SHOW_FUNC(wait_sessions, SHOW_LONG)
DEF_SHOW_FUNC(yes_transactions, SHOW_LONG)


/* plugin status variables */
static SHOW_VAR semi_sync_master_status_vars[]= {
  {"Rpl_semi_sync_master_clients",    (char*) &SHOW_FNAME(clients),         SHOW_FUNC},
  {"Rpl_semi_sync_master_net_avg_wait_time",
                               (char*) &SHOW_FNAME(net_wait_time),   SHOW_FUNC},
  {"Rpl_semi_sync_master_net_wait_time",
                               (char*) &SHOW_FNAME(net_wait_total_time),   SHOW_FUNC},
  {"Rpl_semi_sync_master_net_waits",  (char*) &SHOW_FNAME(net_wait_num),    SHOW_FUNC},
  {"Rpl_semi_sync_master_no_times",   (char*) &SHOW_FNAME(off_times),       SHOW_FUNC},
  {"Rpl_semi_sync_master_no_tx",      (char*) &SHOW_FNAME(no_transactions), SHOW_FUNC},
  {"Rpl_semi_sync_master_status",     (char*) &SHOW_FNAME(status),          SHOW_FUNC},
  {"Rpl_semi_sync_master_timefunc_failures",
                               (char*) &SHOW_FNAME(timefunc_fails),  SHOW_FUNC},
  {"Rpl_semi_sync_master_tx_avg_wait_time",
                               (char*) &SHOW_FNAME(trx_wait_time),   SHOW_FUNC},
  {"Rpl_semi_sync_master_tx_wait_time",
                               (char*) &SHOW_FNAME(trx_wait_total_time),   SHOW_FUNC},
  {"Rpl_semi_sync_master_tx_waits",   (char*) &SHOW_FNAME(trx_wait_num),    SHOW_FUNC},
  {"Rpl_semi_sync_master_wait_pos_backtraverse",
                               (char*) &SHOW_FNAME(back_wait_pos),   SHOW_FUNC},
  {"Rpl_semi_sync_master_wait_sessions",
                               (char*) &SHOW_FNAME(wait_sessions),   SHOW_FUNC},
  {"Rpl_semi_sync_master_yes_tx",     (char*) &SHOW_FNAME(yes_transactions), SHOW_FUNC},
  {NULL, NULL, SHOW_LONG},
};


static int semi_sync_master_plugin_init(void *p)
{
  if (repl_semisync.initObject())
    return 1;
  if (register_trans_observer(&trans_observer, p))
    return 1;
  if (register_binlog_storage_observer(&storage_observer, p))
    return 1;
  if (register_binlog_transmit_observer(&transmit_observer, p))
    return 1;
  return 0;
}

static int semi_sync_master_plugin_deinit(void *p)
{
  if (unregister_trans_observer(&trans_observer, p))
  {
    sql_print_error("unregister_trans_observer failed");
    return 1;
  }
  if (unregister_binlog_storage_observer(&storage_observer, p))
  {
    sql_print_error("unregister_binlog_storage_observer failed");
    return 1;
  }
  if (unregister_binlog_transmit_observer(&transmit_observer, p))
  {
    sql_print_error("unregister_binlog_transmit_observer failed");
    return 1;
  }
  sql_print_information("unregister_replicator OK");
  return 0;
}

struct Mysql_replication semi_sync_master_plugin= {
  MYSQL_REPLICATION_INTERFACE_VERSION
};

/*
  Plugin library descriptor
*/
mysql_declare_plugin(semi_sync_master)
{
  MYSQL_REPLICATION_PLUGIN,
  &semi_sync_master_plugin,
  "rpl_semi_sync_master",
  "He Zhenxing",
  "Semi-synchronous replication master",
  PLUGIN_LICENSE_GPL,
  semi_sync_master_plugin_init, /* Plugin Init */
  semi_sync_master_plugin_deinit, /* Plugin Deinit */
  0x0100 /* 1.0 */,
  semi_sync_master_status_vars,	/* status variables */
  semi_sync_master_system_vars,	/* system variables */
  NULL                        /* config options                  */
}
mysql_declare_plugin_end;