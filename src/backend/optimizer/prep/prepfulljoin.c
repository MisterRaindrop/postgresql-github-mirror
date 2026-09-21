/*-------------------------------------------------------------------------
 *
 * prepfulljoin.c
 *    Experimental FULL JOIN decomposition before planner preprocessing.
 *
 * A FULL JOIN B ON q = (A LEFT JOIN B ON q)
 *                     UNION ALL (B ANTI JOIN A ON q),
 * with typed NULLs for A's columns in the second arm.  In particular, q
 * need not be strict or an equality, and neither input needs a unique key.
 *
 * Copyright (c) 2026, PostgreSQL Global Development Group
 *
 * IDENTIFICATION
 *    src/backend/optimizer/prep/prepfulljoin.c
 *-------------------------------------------------------------------------
 */
#include "postgres.h"

#include "catalog/pg_class.h"
#include "catalog/pg_type.h"
#include "miscadmin.h"
#include "nodes/makefuncs.h"
#include "nodes/nodeFuncs.h"
#include "optimizer/cost.h"
#include "optimizer/optimizer.h"
#include "optimizer/prep.h"
#include "parser/parsetree.h"
#include "rewrite/rewriteManip.h"
#include "utils/lsyscache.h"

bool enable_full_join_rewrite = false;

/* Bound expansion of nested FULL joins, independently of join_collapse_limit. */
#define FULL_JOIN_REWRITE_LIMIT 8

typedef struct FullJoinRewriteContext
{
	Query	   *query;
	JoinExpr   *join;
	Relids		relids;
	Index		newrti;
	int			sublevels_up;
	List	   *vars;
} FullJoinRewriteContext;

static Node *rewrite_full_join_queries(Node *node, int *remaining);
static Query *rewrite_full_join_query(Query *query, int *remaining);
static bool unsafe_full_join_input(Node *node, void *context);
static bool has_record_wholerow(Node *node, void *context);
static bool full_join_has_volatile(Node *node, void *context);
static JoinExpr *find_full_join(Node *node, Relids skipped);
static Node *flatten_full_join_aliases(Node *node, Query *query);
static Node *remap_full_join_vars(Node *node, FullJoinRewriteContext *context);
static Query *decompose_full_join(Query *query, JoinExpr *join);

/* Called once, before any pull-up, SubPlan construction, or PHV creation. */
Query *
rewrite_full_joins(Query *parse)
{
	int			remaining = FULL_JOIN_REWRITE_LIMIT;

	if (!enable_full_join_rewrite || parse->commandType != CMD_SELECT ||
		parse->hasModifyingCTE || parse->hasRecursive)
		return parse;

	return rewrite_full_join_query(parse, &remaining);
}

static Node *
rewrite_full_join_queries(Node *node, int *remaining)
{
	if (node == NULL)
		return NULL;
	if (IsA(node, Query))
		return (Node *) rewrite_full_join_query((Query *) node, remaining);
	return expression_tree_mutator(node, rewrite_full_join_queries, remaining);
}

/*
 * Conservative exclusions for trees that would be evaluated twice.  Besides
 * side effects, sampling, order-sensitive aggregates, and row selection
 * without a unique order cannot be reproduced reliably by two independently
 * planned copies.  CTE references and LATERAL need a separate scope and
 * parameterization design; do not move them.
 */
static bool
unsafe_full_join_input(Node *node, void *context)
{
	if (node == NULL)
		return false;
	/* Defaults are inserted later, and could themselves be volatile. */
	if (IsA(node, FuncExpr) &&
		get_func_nargs(((FuncExpr *) node)->funcid) >
		list_length(((FuncExpr *) node)->args))
		return true;
	/* Domain CHECK expressions are not visited by expression_tree_walker. */
	if (IsA(node, CoerceToDomain))
		return true;
	if (IsA(node, Query))
	{
		Query	   *query = (Query *) node;

		if (query->commandType != CMD_SELECT || query->hasModifyingCTE ||
			query->hasRecursive || query->cteList || query->rowMarks ||
			query->hasRowSecurity || query->limitCount || query->limitOffset ||
			query->hasAggs || query->hasWindowFuncs || query->hasTargetSRFs ||
			query->distinctClause)
			return true;
		return query_tree_walker(query, unsafe_full_join_input, context,
								 QTW_EXAMINE_RTES_BEFORE);
	}
	if (IsA(node, RangeTblEntry))
	{
		RangeTblEntry *rte = (RangeTblEntry *) node;

		if (rte->lateral || rte->tablesample || rte->security_barrier ||
			rte->securityQuals || rte->rtekind == RTE_CTE ||
			rte->rtekind == RTE_FUNCTION || rte->rtekind == RTE_TABLEFUNC ||
			rte->rtekind == RTE_NAMEDTUPLESTORE ||
			(rte->rtekind == RTE_RELATION &&
			 rte->relkind == RELKIND_FOREIGN_TABLE))
			return true;
		return false;			/* range_table_entry_walker visits contents */
	}
	if (IsA(node, SetOperationStmt))
	{
		SetOperationStmt *op = (SetOperationStmt *) node;

		/* Duplicate elimination can select different equal representatives. */
		if (op->op != SETOP_UNION || !op->all)
			return true;
	}
	return expression_tree_walker(node, unsafe_full_join_input, context);
}

static bool
full_join_has_volatile(Node *node, void *context)
{
	return contain_volatile_functions(node);
}

/*
 * Flattening a nullable whole-row JOIN alias needs a PlaceHolderVar.  This
 * pass deliberately precedes PHV creation.  Named table row types are fine;
 * anonymous record whole-row references are left to the existing planner.
 */
static bool
has_record_wholerow(Node *node, void *context)
{
	if (node == NULL)
		return false;
	if (IsA(node, Var))
	{
		Var		   *var = (Var *) node;

		return var->varattno == 0 && var->vartype == RECORDOID;
	}
	if (IsA(node, Query))
		return query_tree_walker((Query *) node, has_record_wholerow,
								 context, 0);
	return expression_tree_walker(node, has_record_wholerow, context);
}

/* Find the innermost remaining FULL join at this query level. */
static JoinExpr *
find_full_join(Node *node, Relids skipped)
{
	JoinExpr   *found;
	ListCell   *lc;

	check_stack_depth();
	if (node == NULL || IsA(node, RangeTblRef))
		return NULL;
	if (IsA(node, FromExpr))
	{
		foreach(lc, ((FromExpr *) node)->fromlist)
			if ((found = find_full_join(lfirst(lc), skipped)) != NULL)
				return found;
	}
	else if (IsA(node, JoinExpr))
	{
		JoinExpr   *join = (JoinExpr *) node;

		if ((found = find_full_join(join->larg, skipped)) != NULL)
			return found;
		if ((found = find_full_join(join->rarg, skipped)) != NULL)
			return found;
		if (join->jointype == JOIN_FULL &&
			!bms_is_member(join->rtindex, skipped))
			return join;
	}
	return NULL;
}

static Node *
flatten_full_join_aliases(Node *node, Query *query)
{
	return flatten_join_alias_for_parser(query, node, 0);
}

static Query *
rewrite_full_join_query(Query *query, int *remaining)
{
	Relids		skipped = NULL;
	JoinExpr   *join;
	bool		flattened = false;

	check_stack_depth();
	if (*remaining == 0 || query->commandType != CMD_SELECT ||
		query->hasModifyingCTE || query->hasRecursive || query->rowMarks)
		return query;

	/* First handle original subqueries, including those in expressions. */
	query = query_tree_mutator(query, rewrite_full_join_queries, remaining, 0);
	if (query_tree_walker(query, has_record_wholerow, NULL, 0))
		return query;

	while (*remaining > 0 &&
		   (join = find_full_join((Node *) query->jointree, skipped)) != NULL)
	{
		Relids		relids = get_relids_in_jointree((Node *) join, true, true);
		int			rti = -1;
		bool		unsafe;

		unsafe = contain_volatile_functions((Node *) join) ||
			unsafe_full_join_input((Node *) join, NULL);
		while (!unsafe && (rti = bms_next_member(relids, rti)) >= 0)
		{
			RangeTblEntry *rte = rt_fetch(rti, query->rtable);

			unsafe = range_table_entry_walker(rte, unsafe_full_join_input, NULL,
											  QTW_EXAMINE_RTES_BEFORE) ||
				range_table_entry_walker(rte, full_join_has_volatile,
											 NULL, 0);
		}
		if (unsafe)
		{
			skipped = bms_add_member(skipped, join->rtindex);
			continue;
		}

		/* Expand USING/NATURAL aliases before separating their input Vars. */
		if (!flattened)
		{
			query = query_tree_mutator(query, flatten_full_join_aliases, query, 0);
			flattened = true;
			join = find_full_join((Node *) query->jointree, skipped);
		}
		query = decompose_full_join(query, join);
		--*remaining;
	}
	return query;
}

/* Preserve RT indexes while removing entries that moved to another scope. */
static List *
full_join_rtable(List *rtable, Relids relids, bool keep_members)
{
	List	   *result = NIL;
	ListCell   *lc;
	int			rti = 0;

	foreach(lc, rtable)
	{
		RangeTblEntry *rte = lfirst_node(RangeTblEntry, lc);

		if (bms_is_member(++rti, relids) == keep_members)
			result = lappend(result, copyObject(rte));
		else
		{
			RangeTblEntry *dummy = makeNode(RangeTblEntry);

			dummy->rtekind = RTE_RESULT;
			dummy->eref = copyObject(rte->eref);
			result = lappend(result, dummy);
		}
	}
	return result;
}

/*
 * Export each required input Var through the UNION.  Strip only nullingrels
 * inside the extracted subtree from the parent Var; ancestor outer joins
 * still null the new subquery.  Conversely, an arm's Var retains only local
 * nullingrels.  Visit correlated references in nested subqueries as well.
 */
static Node *
remap_full_join_vars(Node *node, FullJoinRewriteContext *context)
{
	if (node == NULL)
		return NULL;
	if (node == (Node *) context->join && context->sublevels_up == 0)
	{
		RangeTblRef *ref = makeNode(RangeTblRef);

		ref->rtindex = context->newrti;
		return (Node *) ref;
	}
	if (IsA(node, Var))
	{
		Var		   *var = (Var *) node;
		Var		   *local;
		Var		   *result;
		ListCell   *lc;
		int			attno = 1;

		if (var->varlevelsup != context->sublevels_up ||
			!bms_is_member(var->varno, context->relids))
			return copyObject(node);
		Assert(rt_fetch(var->varno, context->query->rtable)->rtekind != RTE_JOIN);
		local = copyObject(var);
		local->varlevelsup = 0;
		local->varnullingrels = bms_intersect(var->varnullingrels, context->relids);
		local->varnosyn = local->varno;
		local->varattnosyn = local->varattno;
		local->location = -1;
		foreach(lc, context->vars)
		{
			if (equal(local, lfirst(lc)))
				break;
			attno++;
		}
		if (lc == NULL)
			context->vars = lappend(context->vars, local);
		result = makeVar(context->newrti, attno, var->vartype, var->vartypmod,
						 var->varcollid, var->varlevelsup);
		result->varnullingrels = bms_difference(var->varnullingrels, context->relids);
		result->location = var->location;
		return (Node *) result;
	}
	if (IsA(node, Query))
	{
		Query	   *result;

		context->sublevels_up++;
		result = query_tree_mutator((Query *) node, remap_full_join_vars,
									context, 0);
		context->sublevels_up--;
		return (Node *) result;
	}
	return expression_tree_mutator(node, remap_full_join_vars, context);
}

static RangeTblEntry *
full_join_subquery_rte(Query *query, const char *name)
{
	RangeTblEntry *rte = makeNode(RangeTblEntry);
	List	   *names = NIL;
	ListCell   *lc;

	foreach(lc, query->targetList)
	{
		TargetEntry *tle = lfirst_node(TargetEntry, lc);

		names = lappend(names, makeString(pstrdup(tle->resname)));
	}
	/* No permissions belong to a synthetic subquery RTE. */
	rte->rtekind = RTE_SUBQUERY;
	rte->subquery = query;
	rte->eref = makeAlias(name, names);
	rte->inFromCl = true;
	return rte;
}

static Query *
decompose_full_join(Query *query, JoinExpr *join)
{
	FullJoinRewriteContext context;
	Query	   *parent = copyObject(query);
	Query	   *left = makeNode(Query);
	Query	   *anti;
	Query	   *setop = makeNode(Query);
	SetOperationStmt *op = makeNode(SetOperationStmt);
	RangeTblRef *lref = makeNode(RangeTblRef);
	RangeTblRef *rref = makeNode(RangeTblRef);
	Relids		leftids = get_relids_in_jointree(join->larg, true, true);
	Relids		rightids = get_relids_in_jointree(join->rarg, true, true);
	Relids		joinid = bms_make_singleton(join->rtindex);
	JoinExpr   *lj;
	JoinExpr   *aj;
	ListCell   *lc;
	int			attno = 0;

	memset(&context, 0, sizeof(context));
	context.query = query;
	context.join = join;
	context.relids = get_relids_in_jointree((Node *) join, true, true);
	context.newrti = list_length(query->rtable) + 1;

	/* Keep the original jointree pointer so the mutator can identify join. */
	parent->jointree = query->jointree;
	parent->rtable = full_join_rtable(query->rtable, context.relids, false);
	parent = query_tree_mutator(parent, remap_full_join_vars, &context, 0);

	left->commandType = CMD_SELECT;
	left->querySource = QSRC_ORIGINAL;
	left->canSetTag = false;
	left->hasSubLinks = query->hasSubLinks;
	left->rtable = full_join_rtable(query->rtable, context.relids, true);
	left->rteperminfos = copyObject(query->rteperminfos);
	lj = copyObject(join);
	left->jointree = makeFromExpr(list_make1(lj), NULL);
	foreach(lc, context.vars)
	{
		Var		   *var = lfirst_node(Var, lc);

		++attno;
		left->targetList = lappend(left->targetList,
								   makeTargetEntry((Expr *) copyObject(var), attno,
												   psprintf("fj_%d", attno), false));
	}
	/* SELECT count(*)/constants still needs a nonempty UNION target list. */
	if (left->targetList == NIL)
		left->targetList = list_make1(makeTargetEntry((Expr *) makeConst(INT4OID,
										 -1, InvalidOid, sizeof(int32),
										 Int32GetDatum(1), false, true),
										 1, pstrdup("fj_dummy"), false));

	anti = copyObject(left);
	aj = linitial_node(JoinExpr, anti->jointree->fromlist);
	aj->jointype = JOIN_ANTI;
	aj->larg = copyObject(join->rarg);
	aj->rarg = copyObject(join->larg);
	/* No output references the anti join itself, or its now-hidden RHS. */
	aj->rtindex = 0;
	anti->rtable = full_join_rtable(anti->rtable, joinid, false);
	foreach(lc, anti->targetList)
	{
		TargetEntry *tle = lfirst_node(TargetEntry, lc);

		if (IsA(tle->expr, Var) &&
			bms_is_member(((Var *) tle->expr)->varno, leftids))
			tle->expr = (Expr *) makeNullConst(exprType((Node *) tle->expr),
												 exprTypmod((Node *) tle->expr),
												 exprCollation((Node *) tle->expr));
	}
	anti = (Query *) remove_nulling_relids((Node *) anti, joinid, NULL);

	lj->jointype = JOIN_LEFT;
	rt_fetch(join->rtindex, left->rtable)->jointype = JOIN_LEFT;
	left = (Query *) remove_nulling_relids((Node *) left, joinid, rightids);

	/* Existing references to enclosing queries cross two new query levels. */
	IncrementVarSublevelsUp((Node *) left, 2, 1);
	IncrementVarSublevelsUp((Node *) anti, 2, 1);

	setop->commandType = CMD_SELECT;
	setop->querySource = QSRC_ORIGINAL;
	setop->rtable = list_make2(full_join_subquery_rte(left, "fj_left"),
							  full_join_subquery_rte(anti, "fj_anti"));
	setop->jointree = makeFromExpr(NIL, NULL);
	lref->rtindex = 1;
	rref->rtindex = 2;
	op->op = SETOP_UNION;
	op->all = true;
	op->larg = (Node *) lref;
	op->rarg = (Node *) rref;
	foreach(lc, left->targetList)
	{
		TargetEntry *tle = lfirst_node(TargetEntry, lc);
		Node	   *expr = (Node *) tle->expr;
		Var		   *var = makeVar(1, tle->resno, exprType(expr),
								 exprTypmod(expr), exprCollation(expr), 0);

		setop->targetList = lappend(setop->targetList,
									makeTargetEntry((Expr *) var, tle->resno,
													pstrdup(tle->resname), false));
		op->colTypes = lappend_oid(op->colTypes, exprType(expr));
		op->colTypmods = lappend_int(op->colTypmods, exprTypmod(expr));
		op->colCollations = lappend_oid(op->colCollations, exprCollation(expr));
	}
	setop->setOperations = (Node *) op;
	parent->rtable = lappend(parent->rtable,
							full_join_subquery_rte(setop, "fj_union"));
	return parent;
}
