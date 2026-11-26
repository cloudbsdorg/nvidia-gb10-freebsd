/*
 * Copyright (c) 2026 REVYTECH, Inc.
 * SPDX-License-Identifier: BSD-3-Clause
 *
 * nvga_policy.h - the policy of the GPU access check (Track #2374) and of
 * the wired GPU memory accounting (Track #2376), as pure logic.
 *
 * No kernel type appears in this file: the decisions are taken from plain
 * facts about a credential (uid, groups, jail) and from the rules the
 * administrator set.  tests/gpu_access_test.sh compiles this file in
 * userland against fakes of the kernel and runs it, so every rule here is
 * exercised without a GPU and without a jail.
 *
 * The rules, in one place:
 *
 *   - The RM nodes are owned by one group (the group that owns the device
 *     nodes, "video" by default) and their mode is 0660, so the rule for
 *     using a GPU is the node's own permission test: a credential outside a
 *     jail may use a GPU when it is in that group.  The host root may use
 *     every GPU.
 *   - A credential in a jail may use a GPU only when the administrator
 *     granted that jail that GPU (hw.nvidia.gpu_access_jails).  A jail is
 *     granted nothing by default: the grant is the explicit decision, and
 *     the jail's own devfs rules decide which nodes the jail can see.
 *   - The wired memory of the GPU is charged to the credential that asked
 *     for it, per uid and per jail, and an allocation over a limit is
 *     refused before the memory is handed out.
 */
#ifndef NVGA_POLICY_H_
#define NVGA_POLICY_H_

#include <sys/types.h>

/* the groups of one credential that the policy looks at */
#define	NVGA_MAX_GROUPS		16
/* the jails that can hold a grant at once */
#define	NVGA_MAX_JAILS		16
/* the GPU units one jail can hold at once */
#define	NVGA_MAX_UNITS		64
/* the uids whose wired total is tracked at once */
#define	NVGA_UID_SLOTS		128

/* the answer of the access check */
#define	NVGA_ALLOW		0	/* the credential may use the GPU */
#define	NVGA_DENY_JAIL		1	/* the jail was not granted the GPU */
#define	NVGA_DENY_GROUP		2	/* the credential is not in the group */
#define	NVGA_DENY_NO_UNIT	3	/* there is no such GPU */

/* the facts about a credential the policy needs */
struct nvga_cred {
	uint32_t	uid;
	uint32_t	groups[NVGA_MAX_GROUPS];
	int		ngroups;
	int		jail_id;	/* -1: not in a jail */
};

/* what one jail may use */
struct nvga_jail_grant {
	int	jail_id;
	int	nunits;
	int	units[NVGA_MAX_UNITS];
};

/* the rules in force */
struct nvga_rules {
	uint32_t		node_gid;	/* the group that owns the nodes */
	int			allow_root;	/* 1: the host root may use every GPU */
	int			njails;
	struct nvga_jail_grant	jails[NVGA_MAX_JAILS];
};

/* the limits of the wired memory accounting */
struct nvga_limits {
	uint64_t	per_credential;	/* 0: unlimited */
	uint64_t	total;		/* 0: unlimited */
	uint64_t	rctl;		/* the rctl deny cap, 0: none */
};

/* one tracked total (per uid or per jail) */
struct nvga_counter {
	uint32_t	uid;		/* the uid, or the jail id */
	uint64_t	bytes;
	int		used;
};

/*
 * nvga_cred_in_group - is the credential in this group?
 */
static inline int
nvga_cred_in_group(const struct nvga_cred *cred, uint32_t gid)
{
	int i;

	for (i = 0; i < cred->ngroups; i++) {
		if (cred->groups[i] == gid)
			return (1);
	}
	return (0);
}

/*
 * nvga_jail_granted - did the jail get this unit?
 */
static inline int
nvga_jail_granted(const struct nvga_rules *rules, int jail_id, int unit)
{
	int j, u;

	for (j = 0; j < rules->njails; j++) {
		if (rules->jails[j].jail_id != jail_id)
			continue;
		for (u = 0; u < rules->jails[j].nunits; u++) {
			if (rules->jails[j].units[u] == unit)
				return (1);
		}
		return (0);
	}
	return (0);
}

/*
 * nvga_may_use - may this credential use this GPU unit?
 *
 * A unit below zero is not a GPU (the control device), and is allowed.
 * A credential in a jail is decided by the jail's grant alone: the jail's
 * root is not the host root, and the jail's devfs rules decide which nodes
 * the jail can see at all.
 * Outside a jail the host root may use every GPU, and every other
 * credential may use a GPU when it is in the group that owns the nodes.
 * Everything else is refused.
 */
static inline int
nvga_may_use(const struct nvga_cred *cred, int unit, const struct nvga_rules *rules)
{
	if (unit < 0)
		return (NVGA_ALLOW);
	if (cred->jail_id >= 0) {
		if (nvga_jail_granted(rules, cred->jail_id, unit))
			return (NVGA_ALLOW);
		return (NVGA_DENY_JAIL);
	}
	if (rules->allow_root && cred->uid == 0)
		return (NVGA_ALLOW);
	if (nvga_cred_in_group(cred, rules->node_gid))
		return (NVGA_ALLOW);
	return (NVGA_DENY_GROUP);
}

/*
 * nvga_fmt_add - add this text to the string in the buffer.
 *
 * The text is added only when it fits whole: a string that is cut in half
 * is a lie twice over (the reader sees a grant that is not there, and a
 * read followed by a write would drop the grant that did not fit), and the
 * length the caller reports must never be longer than the buffer that
 * holds the string.  *full is set when the text did not fit, and nothing
 * more is added after that.
 *
 * The rule lives here, and not in the glue, because it is a rule about a
 * buffer and a length: the harness calls it with a buffer that is too
 * small and watches it refuse to write past the end.
 */
static inline size_t
nvga_fmt_add(char *buf, size_t len, size_t off, int *full, const char *text)
{
	size_t slen;

	if (*full)
		return (off);
	slen = strlen(text);
	if (slen + 1 > len - off) {		/* it does not fit */
		*full = 1;
		return (off);
	}
	memcpy(buf + off, text, slen + 1);
	return (off + slen);
}

/*
 * nvga_over - would this request go over a limit?  The sums are computed
 * without an addition that can wrap: a request that does not fit in the
 * limit is over it.
 */
static inline int
nvga_over(uint64_t total, uint64_t bytes, uint64_t limit)
{
	if (limit == 0)
		return (0);
	if (total > limit)
		return (1);
	return (bytes > limit - total);
}

/*
 * nvga_wired_allowed - may this allocation of this many bytes go ahead?
 *
 * The user's own total (the uid, whether or not the caller is in a jail),
 * the jail's own total (when the caller is in one), the host's total and
 * the rctl deny cap are all checked; the first one that the request goes
 * over refuses it.
 *
 * Inside a jail both the user and the jail are checked: the limit is about
 * what one user may hold and about what one jail may hold, and the
 * tighter of the two holds.
 */
static inline int
nvga_wired_allowed(uint64_t cred_total, uint64_t jail_total, int in_jail,
    uint64_t total, uint64_t bytes, const struct nvga_limits *limits)
{
	if (nvga_over(cred_total, bytes, limits->per_credential))
		return (0);
	if (in_jail && nvga_over(jail_total, bytes, limits->per_credential))
		return (0);
	if (nvga_over(total, bytes, limits->total))
		return (0);
	if (nvga_over(cred_total, bytes, limits->rctl))
		return (0);
	if (in_jail && nvga_over(jail_total, bytes, limits->rctl))
		return (0);
	return (1);
}

/*
 * nvga_counter_find - the slot of this uid, or the first free slot when
 * create is set.  Returns -1 when the table is full: the caller refuses
 * the allocation rather than lose the total.
 */
static inline int
nvga_counter_find(struct nvga_counter *table, int slots, uint32_t uid, int create)
{
	int i, free_slot = -1;

	for (i = 0; i < slots; i++) {
		if (table[i].used && table[i].uid == uid)
			return (i);
		if (!table[i].used && free_slot < 0)
			free_slot = i;
	}
	if (create && free_slot >= 0) {
		table[free_slot].used = 1;
		table[free_slot].uid = uid;
		table[free_slot].bytes = 0;
		return (free_slot);
	}
	return (-1);
}

/*
 * nvga_skip_sep - move past the separators between the grants.
 *
 * The separators are the ';', the spaces and the tabs, and they may stand
 * anywhere between two grants.
 */
static inline const char *
nvga_skip_sep(const char *p)
{
	while (*p == ';' || *p == ' ' || *p == '\t')
		p++;
	return (p);
}

/*
 * nvga_grant_is_all - is this the "all" of a grant?
 *
 * "all" grants every unit.  Only the word itself and the end of the grant
 * may follow it, so that a unit whose name begins with the letters of the
 * word ("alley") is not read as "all".
 */
static inline int
nvga_grant_is_all(const char *p)
{
	if (strncmp(p, "all", 3) != 0)
		return (0);
	if (p[3] == '\0' || p[3] == ';' || p[3] == ' ')
		return (1);
	return (0);
}

/*
 * nvga_parse_jail_id - read the jail id of one grant.
 *
 * The id is a number, and the ':' that follows it; both are consumed.  A
 * grant without a number, or without the ':', is refused (-1).
 */
static inline int
nvga_parse_jail_id(const char **pp, int *jail_id)
{
	const char *p = *pp;
	char *end;
	long id;

	id = strtol(p, &end, 10);
	if (end == p || id < 0 || id > 0x7fffffff)
		return (-1);
	if (*end != ':')
		return (-1);
	*jail_id = (int)id;
	*pp = end + 1;
	return (0);
}

/*
 * nvga_parse_grant_units - read the units of one grant.
 *
 * The units are "all", or a list of unit numbers separated by ','.  The
 * pointer is left on the first character that is not part of the units.
 * A malformed list is refused (-1).
 */
static inline int
nvga_parse_grant_units(const char **pp, struct nvga_jail_grant *grant)
{
	const char *p = *pp;
	long unit;
	char *end;
	int n;

	grant->nunits = 0;
	if (nvga_grant_is_all(p)) {
		for (n = 0; n < NVGA_MAX_UNITS; n++)
			grant->units[n] = n;
		grant->nunits = NVGA_MAX_UNITS;
		*pp = p + 3;
		return (0);
	}
	while (*p != '\0' && *p != ';') {
		if (*p == ' ' || *p == '\t') {
			p++;
			continue;
		}
		unit = strtol(p, &end, 10);
		if (end == p || unit < 0 || unit >= NVGA_MAX_UNITS)
			return (-1);
		p = end;
		if (grant->nunits >= NVGA_MAX_UNITS)
			return (-1);
		grant->units[grant->nunits++] = (int)unit;
		if (*p == ',')
			p++;
		else if (*p != '\0' && *p != ';')
			return (-1);
	}
	*pp = p;
	return (0);
}

/*
 * nvga_parse_jails - read the jail grants from a string.
 *
 * The string is a list of grants separated by ';', each grant a jail id
 * and the units it may use separated by ':' and ','.  "3:0" grants unit 0
 * to jail 3, "3:0,1" grants units 0 and 1, "3:all" grants every unit.
 * An empty string grants nothing.  A malformed string is refused whole:
 * the rules in force stay the ones that were there.
 *
 * The reading is in three parts, so that no one of them holds the whole
 * grammar: the separators between the grants, the jail id of a grant, and
 * the units of a grant.
 */
static inline int
nvga_parse_jails(const char *s, struct nvga_rules *rules)
{
	struct nvga_rules parsed;
	const char *p;
	int njails = 0;

	if (s == NULL)
		return (-1);
	parsed = *rules;
	parsed.njails = 0;
	p = s;

	for (;;) {
		p = nvga_skip_sep(p);
		if (*p == '\0')
			break;
		if (njails >= NVGA_MAX_JAILS)
			return (-1);
		if (nvga_parse_jail_id(&p, &parsed.jails[njails].jail_id) != 0)
			return (-1);
		if (nvga_parse_grant_units(&p, &parsed.jails[njails]) != 0)
			return (-1);
		njails++;
	}
	parsed.njails = njails;
	*rules = parsed;
	return (0);
}

#endif /* NVGA_POLICY_H_ */
