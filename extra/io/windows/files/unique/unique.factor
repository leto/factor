USING: kernel system ;
IN: io.windows.files.unique

M: windows-io (make-unique-file) ( path -- stream )
    GENERIC_WRITE CREATE_NEW 0 open-file 0 <writer> ;

M: windows-io temporary-path ( -- path )
    "TEMP" os-env ;