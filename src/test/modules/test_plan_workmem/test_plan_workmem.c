/*-------------------------------------------------------------------------
 *
 * test_plan_workmem.c
 *		Test module for the per-node working-memory limit (Plan.workmem).
 *
 * A planner hook sets the workmem field of every node of the plan to
 * test_plan_workmem.node_limit, so that tests can check that the executor
 * enforces the node's limit rather than work_mem.
 *
 * Copyright (c) 2026, PostgreSQL Global Development Group
 *
 * IDENTIFICATION
 *	  src/test/modules/test_plan_workmem/test_plan_workmem.c
 *
 *-------------------------------------------------------------------------
 */
#include "postgres.h"

#include <limits.h>

#include "fmgr.h"
#include "nodes/plannodes.h"
#include "optimizer/planner.h"
#include "utils/guc.h"

PG_MODULE_MAGIC;

/* limit to set on every plan node, in kB; zero leaves the plan alone */
static int	node_limit = 0;

static planner_hook_type prev_planner_hook = NULL;

static void set_node_limit(Plan *plan);

static void
set_node_limit_list(List *plans)
{
	ListCell   *lc;

	foreach(lc, plans)
		set_node_limit((Plan *) lfirst(lc));
}

static void
set_node_limit(Plan *plan)
{
	if (plan == NULL)
		return;

	plan->workmem = node_limit;

	switch (nodeTag(plan))
	{
		case T_Append:
			set_node_limit_list(((Append *) plan)->appendplans);
			break;
		case T_MergeAppend:
			set_node_limit_list(((MergeAppend *) plan)->mergeplans);
			break;
		case T_BitmapAnd:
			set_node_limit_list(((BitmapAnd *) plan)->bitmapplans);
			break;
		case T_BitmapOr:
			set_node_limit_list(((BitmapOr *) plan)->bitmapplans);
			break;
		case T_SubqueryScan:
			set_node_limit(((SubqueryScan *) plan)->subplan);
			break;
		case T_CustomScan:
			set_node_limit_list(((CustomScan *) plan)->custom_plans);
			break;
		default:
			break;
	}
	set_node_limit(outerPlan(plan));
	set_node_limit(innerPlan(plan));
}

static PlannedStmt *
test_plan_workmem_planner(Query *parse, const char *query_string,
						  int cursorOptions, ParamListInfo boundParams,
						  ExplainState *es)
{
	PlannedStmt *result;

	if (prev_planner_hook)
		result = prev_planner_hook(parse, query_string, cursorOptions,
								   boundParams, es);
	else
		result = standard_planner(parse, query_string, cursorOptions,
								  boundParams, es);

	if (node_limit > 0)
	{
		set_node_limit(result->planTree);
		set_node_limit_list(result->subplans);
	}

	return result;
}

void
_PG_init(void)
{
	DefineCustomIntVariable("test_plan_workmem.node_limit",
							"Working memory to set on every plan node.",
							"Zero leaves the plan alone, so nodes use work_mem.",
							&node_limit,
							0, 0, MAX_KILOBYTES,
							PGC_USERSET,
							GUC_UNIT_KB,
							NULL, NULL, NULL);
	MarkGUCPrefixReserved("test_plan_workmem");

	prev_planner_hook = planner_hook;
	planner_hook = test_plan_workmem_planner;
}
