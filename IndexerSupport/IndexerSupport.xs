/* Fast sorting and merging for XAO::Indexer
 *
 * Andrew Maltsev, <am@xao.com>, 2004
*/
#define PERL_NO_GET_CONTEXT
#include "EXTERN.h"
#include "perl.h"
#include "XSUB.h"
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <ctype.h>

/* If that version of perl does not have pTHX_ macros then defining them here
*/
#ifndef	pTHX_
#define	pTHX_
#endif
#ifndef	aTHX_
#define	aTHX_
#endif

/************************************************************************/

#define TREE_DEPTH  (5)
#define LEAF_SIZE   (0x80000000>>(TREE_DEPTH*4-1))
#define MAX_ISECT   100

/************************************************************************/

union tree_node {
    union tree_node *nodes;
    U32 *data;
};
static union tree_node tree_root[16];

/************************************************************************/

static
void
tree_print(union tree_node *branch, U8 level) {
    U8 spnum=(level+1)*2;
    U8 i;
    for(i=0; i<16; ++i) {
        if(!branch[i].nodes) continue;
        fprintf(stderr,"%*s:idx=%x level=%u\n",spnum,".",i,level);
        if(level<TREE_DEPTH-1) {
            tree_print(branch[i].nodes,level+1);
        }
        else {
            U32 *d=branch[i].data;
            U32 j;
            for(j=0; j<LEAF_SIZE; ++j) {
                U32 pos=d[j];
                if(pos!=0xffffffff) {
                    fprintf(stderr,"%*s:::pos=%5lu value=%04x\n",
                                   spnum,".",pos,j);
                }
            }
        }
    }
}

static
void
tree_store(union tree_node *branch, U32 pos, U32 value, U8 level) {
    U8 idx=((level ? value<<(level*4) : value) >> 28) & 0xf;
    union tree_node *node=branch+idx;

    //printf("pos=%lu value=%08lx level=%u idx=%u\n",pos,value,level,idx);

    if(level<TREE_DEPTH-1) {
        if(!node->nodes) {
            Newz(0,node->nodes,16,union tree_node);
        }
        tree_store(node->nodes,pos,value,level+1);
    }
    else {
        U32 *data=node->data;
        if(!node->data) {
            New(0,data,LEAF_SIZE,U32);
            memset(data,0xff,LEAF_SIZE*sizeof(U32));
            node->data=data;
        }
        data[value&(LEAF_SIZE-1)]=pos;
    }
}

/* Only clears data blocks without even freeing their memory, since if
 * we're going to re-use the index -- it will most likely contain the same
 * ID's, only re-ordered.
*/
static
void
tree_clear(union tree_node *branch, U8 level) {
    U8 i;
    for(i=0; i<16; ++i) {
        if(level<TREE_DEPTH-1) {
            union tree_node *nodes=branch[i].nodes;
            if(nodes) {
                //printf("Clearing level=%x, i=%x\n",level,i);
                tree_clear(nodes,level+1);
            }
        }
        else {
            U32 *data=branch[i].data;
            if(data) {
                memset(data,0xff,LEAF_SIZE * sizeof(*data));
            }
        }
    }
}

/* Populating tree with data
*/
static
void
tree_init(U32 *data, U32 size) {
    U32 i;

    tree_clear(tree_root,0);

    for(i=0; i<size; ++i, ++data) {
        U32 value=*data;
        tree_store(tree_root,i,value,0);
    }
}

static
U32
tree_lookup(U32 value) {
    union tree_node *node=tree_root;
    U8 i;
    U16 vrem;
    U16 qty;

    //printf("Looking up %08lx (%lu)\n",value,value);

    for(i=0; i<TREE_DEPTH; ++i) {
        
        U8 idx=((i ? value<<(i*4) : value) >> 28) & 0xf;
        if(!node) {
            return 0xffffffff;
        }
        if(i==TREE_DEPTH-1) {
            U32 *data=node[idx].data;
            if(!data)
                return 0xffffffff;
            return data[value & (LEAF_SIZE-1)];
        }
        else {
            node=node[idx].nodes;
            //printf("i=%u idx=%u node=%p\n",i,idx,node);
        }
    }

    return 0xffffffff;
}

static
void
tree_free(union tree_node *branch, U8 level) {
    U8 i;

    if(level==0)
        //printf("Freeing branch %p, level %u\n",branch,level);

    for(i=0; i<16; ++i) {
        //printf("Freeing level=%x, i=%x\n",level,i);
        if(level<TREE_DEPTH-1) {
            union tree_node *nodes=branch[i].nodes;
            if(nodes) {
                tree_free(nodes,level+1);
                Safefree(nodes);
                branch[i].nodes=NULL;
            }
        }
        else {
            U32 *data=branch[i].data;
            if(data) {
                Safefree(data);
                branch[i].data=NULL;
            }
        }
    }
}

static
int
tree_compare(U32 const *a, U32 const *b) {
    U32 pa=tree_lookup(*a);
    U32 pb=tree_lookup(*b);
    return (pa>pb ? 1 : (pa<pb ? -1 : 0));
}

/************************************************************************/

static
void
printset(char const *str, U8 list_num, U32 **lists, U32 *sizes) {
    U8 i;
    fprintf(stderr,"%s:\n",str);
    for(i=0; i<list_num; ++i) {
        U8 j;
        fprintf(stderr,"lists[%u]={",i);
        for(j=0; j<sizes[i]; ++j) {
            fprintf(stderr,"%lu,",lists[i][j]);
        }
        fprintf(stderr,"}\n");
    }
}

/************************************************************************/

// Modifies one of the given lists and its size in place and returns its
// index

static
void
sorted_intersection_go(U8 list_num, U32 **lists, U32 *sizes) {
    U8 i8;
    U32 i;
    U32 base_size;
    U32 res_size;
    U32 cursors[MAX_ISECT];

    // If there are no lists or if there is just one list then we don't
    // need to do anything.
    //
    if(list_num<=1)
        return;

    // There is a hard-coded limit on the maximum number of lists.
    //
    if(list_num > sizeof(cursors)/sizeof(*cursors)) {
        list_num=sizeof(cursors)/sizeof(*cursors);
    }

    // First sorting lists so that the shortest is first as obviously
    // intersection can't be longer then the shortest list.
    //
    // We need to sort two short arrays in place at the same time, so
    // doing it bubble-like way.
    //
    //// printset("Initial",list_num,lists,sizes);
    for(i8=0; i8<list_num-1; ++i8) {
        U32 sz=sizes[i8];
        U8 pos=i8;
        U8 j;
        cursors[i8]=0;
        for(j=i8+1; j<list_num; ++j) {
            U32 jsz=sizes[j];
            if(sz>jsz) {
                sz=jsz;
                pos=j;
            }
        }
        if(pos!=i8) {
            U32 *p=lists[pos];
            lists[pos]=lists[i8];
            lists[i8]=p;
            sz=sizes[pos];
            sizes[pos]=sizes[i8];
            sizes[i8]=sz;
        }
    }
    //// printset("Sorted",list_num,lists,sizes);
    cursors[list_num-1]=0;

    // Now keeping positions in the lists and going through them
    // building resulting set in-place in the first position -- both for
    // size and data.
    //
    base_size=sizes[0];
    res_size=0;
    for(i=0; i<base_size; ++i) {
        U32 base_val=lists[0][i];
        U8 j;
        //printf(".checking base_val=%lu, i=%lu, res_size=%lu\n",base_val,i,res_size);
        for(j=1; j<list_num; ++j) {
            U32 *list=lists[j];
            U32 list_size=sizes[j];
            U32 k;
            //printf("..against j=%u, list_size=%lu, cursors[j]=%lu\n",j,list_size,cursors[j]);
            for(k=cursors[j]; k<list_size; ++k) {
                //printf("...k=%lu, list[k]=%lu\n",k,list[k]);
                if(base_val == list[k]) {
                    //printf("....match!\n");
                    cursors[j]=k;
                    break;
                }
            }
            if(k>=list_size) {
                //printf("....no match!\n");
                break;
            }
        }
        if(j>=list_num) {
            if(res_size!=i) {
                lists[0][res_size]=base_val;
            }
            ++res_size;
            //printf("....global match on %lu, res_size=%lu\n",base_val,res_size);
        }
    }
    sizes[0]=res_size;
    //// printset("Intersection",list_num,lists,sizes);
}

/************************************************************************/

MODULE = XAO::IndexerSupport		PACKAGE = XAO::IndexerSupport

 # Gets sorted array that is to be used in templated sorting of its
 # subsets later on.
 #

void
template_sort_prepare_do(full_sv)
        SV *full_sv;
    INIT:
        STRLEN full_strlen;
        U32 *full=(U32 *)SvPV(full_sv,full_strlen);
        U32 full_len=full_strlen/sizeof(U32);
	CODE:
        tree_init(full,full_len);

void
template_sort_do(part_sv)
        SV *part_sv;
    INIT:
        STRLEN part_strlen;
        U32 *part=(U32 *)SvPV(part_sv,part_strlen);
        U32 part_len=part_strlen/sizeof(U32);
	CODE:
        qsort(part,part_len,sizeof(*part),
              (int (*)(const void *,const void *))tree_compare);

int
template_sort_compare(a,b)
        U32 a;
        U32 b;
	CODE:
        RETVAL=tree_compare(&a,&b);
    OUTPUT:
        RETVAL

void
template_sort_clear()
    CODE:
        tree_clear(tree_root,0);

void
template_sort_free()
    CODE:
        tree_free(tree_root,0);

U32
template_sort_position(value)
        U32 value;
    CODE:
        RETVAL=tree_lookup(value);
    OUTPUT:
        RETVAL

void
template_sort_print_tree()
    CODE:
        tree_print(tree_root,0);

SV*
sorted_intersection_do(av_ref)
        SV* av_ref;
    INIT:
        AV*     av=SvRV(av_ref);
        U8      avl=av_len(av)+1;
        U8      i;
        U32*    lists[MAX_ISECT];
        U32     sizes[MAX_ISECT];
    CODE:
        if(avl>MAX_ISECT) {
            fprintf(stderr,"sorted_intersection_do - to many lists (>%u)",MAX_ISECT);
            avl=MAX_ISECT;
        }
        for(i=0; i<avl; ++i) {
            STRLEN slen;
            SV** p_list_sv=av_fetch(av,i,0);
            lists[i]=(U32 *)SvPV(*p_list_sv,slen);
            sizes[i]=slen/sizeof(U32);
        }
        sorted_intersection_go(avl,lists,sizes);
        RETVAL=newSVpvn((const char *)lists[0],sizes[0]*sizeof(U32));
    OUTPUT:
        RETVAL
