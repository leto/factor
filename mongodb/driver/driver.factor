USING: accessors assocs bson.constants bson.writer combinators
constructors continuations destructors formatting fry io io.pools
io.encodings.binary io.sockets io.streams.duplex kernel linked-assocs hashtables
math math.parser memoize mongodb.connection mongodb.msg mongodb.operations namespaces
parser prettyprint sequences sets splitting strings uuid arrays ;

IN: mongodb.driver

TUPLE: mdb-pool < pool mdb ;

TUPLE: mdb-cursor collection id return# ;

UNION: boolean t POSTPONE: f ;

TUPLE: mdb-collection
{ name string }
{ capped boolean initial: f }
{ size integer initial: -1 }
{ max integer initial: -1 } ;

: <mdb-collection> ( name -- collection )
    [ mdb-collection new ] dip >>name ; inline

M: mdb-pool make-connection
    mdb>> mdb-open ;

: <mdb-pool> ( mdb -- pool ) mdb-pool <pool> swap >>mdb ;

CONSTANT: MDB-GENERAL-ERROR 1

CONSTANT: PARTIAL? "partial?"
CONSTANT: DIRTY? "dirty?"

ERROR: mdb-error id msg ;

<PRIVATE

CONSTRUCTOR: mdb-cursor ( id collection return# -- cursor ) ;

: >mdbregexp ( value -- regexp )
   first <mdbregexp> ; inline

PRIVATE>

SYNTAX: r/ ( token -- mdbregexp )
    \ / [ >mdbregexp ]  parse-literal ; 

: with-db ( mdb quot -- ... )
    '[ _ mdb-open &dispose _ with-connection ] with-destructors ; inline
  
: build-id-selector ( assoc -- selector )
    [ MDB_OID_FIELD swap at ] keep
    H{ } clone [ set-at ] keep ;

: make-cursor ( mdb-result-msg -- cursor/f )
    dup cursor>> 0 > 
    [ [ cursor>> ] [ collection>> ] [ requested#>> ] tri <mdb-cursor> ]
    [ drop f ] if ;

: send-query ( query-message -- cursor/f result )
    [ send-query-plain ] keep
    [ collection>> >>collection drop ]
    [ return#>> >>requested# ] 2bi
    [ make-cursor ] [ objects>> ] bi ;

PRIVATE>

: <mdb> ( db host port -- mdb )
   <inet> t [ <mdb-node> ] keep
   H{ } clone [ set-at ] keep <mdb-db>
   [ verify-nodes ] keep ;

GENERIC: create-collection ( name -- )
M: string create-collection
    <mdb-collection> create-collection ;

M: mdb-collection create-collection ( mdb-collection -- )
    [ cmd-collection ] dip
    <linked-hash> [
        [ [ name>> "create" ] dip set-at ]
        [ [ [ capped>> ] keep ] dip
          '[ _ _
             [ [ drop t "capped" ] dip set-at ]
             [ [ size>> "size" ] dip set-at ]
             [ [ max>> "max" ] dip set-at ] 2tri ] when
        ] 2bi
    ] keep <mdb-query-msg> 1 >>return# send-query-plain
    objects>> first check-ok
    [ drop ] [ throw ] if ;

: load-collection-list ( -- collection-list )
    namespaces-collection
    H{ } clone <mdb-query-msg> send-query-plain objects>> ;

<PRIVATE

: ensure-valid-collection-name ( collection -- )
    [ ";$." intersect length 0 > ] keep
    '[ _ "%s contains invalid characters ( . $ ; )" sprintf throw ] when ; inline

USE: tools.continuations

: (ensure-collection) ( collection --  )
    mdb-instance collections>> dup keys length 0 = 
    [ load-collection-list      
      [ [ "options" ] dip key? ] filter
      [ [ "name" ] dip at "." split second <mdb-collection> ] map
      over '[ [ ] [ name>> ] bi _ set-at ] each ] [ ] if
    [ dup ] dip key? [ drop ]
    [ [ ensure-valid-collection-name ] keep create-collection ] if ; inline

MEMO: reserved-namespace? ( name -- ? )
    [ "$cmd" = ] [ "system" head? ] bi or ;
    
MEMO: check-collection ( collection -- fq-collection )
    dup mdb-collection? [ name>> ] when
    "." split1 over mdb-instance name>> =
    [ nip ] [ drop ] if
    [ ] [ reserved-namespace? ] bi
    [ [ (ensure-collection) ] keep ] unless
    [ mdb-instance name>> ] dip "%s.%s" sprintf ; inline

: fix-query-collection ( mdb-query -- mdb-query )
    [ check-collection ] change-collection ; inline
    
PRIVATE>

: <query> ( collection query -- mdb-query )
    <mdb-query-msg> ; inline

GENERIC# limit 1 ( mdb-query limit# -- mdb-query )
M: mdb-query-msg limit ( query limit# -- mdb-query )
    >>return# ; inline

GENERIC# skip 1 ( mdb-query skip# -- mdb-query )
M: mdb-query-msg skip ( query skip# -- mdb-query )
    >>skip# ; inline

: asc ( key -- spec ) [ 1 ] dip H{ } clone [ set-at ] keep ; inline
: desc ( key -- spec ) [ -1 ] dip H{ } clone [ set-at ] keep ; inline

GENERIC# sort 1 ( mdb-query quot -- mdb-query )
M: mdb-query-msg sort ( query qout -- mdb-query )
    [ { } ] dip with-datastack >>orderby ;

GENERIC# hint 1 ( mdb-query index-hint -- mdb-query )
M: mdb-query-msg hint ( mdb-query index-hint -- mdb-query )
    >>hint ;

GENERIC: get-more ( mdb-cursor -- mdb-cursor objects )
M: mdb-cursor get-more ( mdb-cursor -- mdb-cursor objects )
    [ [ collection>> ] [ return#>> ] [ id>> ] tri <mdb-getmore-msg> send-query ] 
    [ f f ] if* ;

GENERIC: find ( mdb-query -- cursor result )
M: mdb-query-msg find
    fix-query-collection send-query ;
M: mdb-cursor find
    get-more ;

GENERIC: explain. ( mdb-query -- )
M: mdb-query-msg explain.
    t >>explain find nip . ;

GENERIC: find-one ( mdb-query -- result/f )
M: mdb-query-msg find-one
    fix-query-collection 
    1 >>return# send-query-plain objects>>
    dup empty? [ drop f ] [ first ] if ;

GENERIC: count ( mdb-query -- result )
M: mdb-query-msg count    
    [ collection>> "count" H{ } clone [ set-at ] keep ] keep
    query>> [ over [ "query" ] dip set-at ] when*
    [ cmd-collection ] dip <mdb-query-msg> find-one 
    [ check-ok nip ] keep '[ "n" _ at >fixnum ] [ f ] if ;

: lasterror ( -- error )
    cmd-collection H{ { "getlasterror" 1 } } <mdb-query-msg>
    find-one [ "err" ] dip at ;

GENERIC: validate. ( collection -- )
M: string validate.
    [ cmd-collection ] dip
    "validate" H{ } clone [ set-at ] keep
    <mdb-query-msg> find-one [ check-ok nip ] keep
    '[ "result" _ at print ] [  ] if ;
M: mdb-collection validate.
    name>> validate. ;

<PRIVATE

: send-message-check-error ( message -- )
    send-message lasterror [ [ MDB-GENERAL-ERROR ] dip mdb-error ] when* ;

PRIVATE>

GENERIC: save ( collection assoc -- )
M: assoc save
    [ check-collection ] dip
    <mdb-insert-msg> send-message-check-error ;

GENERIC: save-unsafe ( collection object -- )
M: assoc save-unsafe
    [ check-collection ] dip
    <mdb-insert-msg> send-message ;

GENERIC: ensure-index ( collection name spec -- )
M: assoc ensure-index
    H{ } clone
    [ [ uuid1 "_id" ] dip set-at ] keep
    [ [ "key" ] dip set-at ] keep
    [ [ "name" ] dip set-at ] keep
    [ [ index-ns "ns" ] dip set-at ] keep
    [ index-collection ] dip
    save ;

: drop-index ( collection name -- )
    H{ } clone
    [ [ "index" ] dip set-at ] keep
    [ [ "deleteIndexes" ] dip set-at ] keep
    [ cmd-collection ] dip <mdb-query-msg>
    find-one drop ;

: <update> ( collection selector object -- update-msg )
    [ check-collection ] 2dip <mdb-update-msg> ;

: >upsert ( mdb-update-msg -- mdb-update-msg )
    1 >>upsert? ; 

GENERIC: update ( mdb-update-msg -- )
M: mdb-update-msg update
    send-message-check-error ;

GENERIC: update-unsafe ( mdb-update-msg -- )
M: mdb-update-msg update-unsafe
    send-message ;
 
GENERIC: delete ( collection selector -- )
M: assoc delete
    [ check-collection ] dip
    <mdb-delete-msg> send-message-check-error ;

GENERIC: delete-unsafe ( collection selector -- )
M: assoc delete-unsafe
    [ check-collection ] dip
    <mdb-delete-msg> send-message ;

: load-index-list ( -- index-list )
    index-collection
    H{ } clone <mdb-query-msg> find nip ;

: ensure-collection ( name -- )
    check-collection drop ;

: drop-collection ( name -- )
    [ cmd-collection ] dip
    "drop" H{ } clone [ set-at ] keep
    <mdb-query-msg> find-one drop ;

: >pwd-digest ( user password -- digest )
    "mongo" swap 3array ":" join md5-checksum ; 

