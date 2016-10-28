with Ada.Streams;
with System;
with Interfaces.C;

with Ratp.Reliable_Udp;

with Buffers;

package Ratp.Buffer_Handling is

   package Packet_Buffers is new
      Buffers.Generic_Buffers
         (Element_Type => Ratp.Packet_Stream);

   --  Index Type for "Handlers" array
   --  "is mod type" enables a circular parsing
   type Handle_Index_Type is mod Ratp.PMH_Buf_Nb;

   --  State of Buffer:
   --  Empty =>  Buf is released
   --  Near_Full => Buf is waiting for acks
   --  Full => Ready to be Released
   type State_Enum_Type is (Empty, Near_Full, Full);

   type Handler_Type is limited
      record
         Handle            : Buffers.Buffer_Handle_Type;
         State             : State_Enum_Type := Empty;
      end record;

   --  Contains all the Handlers
   type Handle_Array_Type is array (Handle_Index_Type) of Handler_Type;

   type Buffer_Handler_Type is
      record
         Handlers          : Handle_Array_Type;
         First             : Handle_Index_Type;
         Current           : Handle_Index_Type;
      end record;

   procedure Perror (Message : String);
   pragma Import (C, Perror, "perror");

   function mlockall (Flags : Interfaces.C.int)
      return Interfaces.C.int;
   pragma Import (C, mlockall, "mlockall");

   function mlock (Addr : System.Address;
                   Len  : Interfaces.C.size_t)
      return Interfaces.C.int;
   pragma Import (C, mlock, "mlock");

   --  Initialize "PMH_Buf_Nb" of Buffer and attach a buffer
   --  to each Handler of Handle_Array
   procedure Init_Buffers;

   --  Release Buffer at Handlers (Index) and change its State to Empty
   procedure Release_Free_Buffer_At (Index   : in Handle_Index_Type);

   --  Search position of ack received in current and previous buffers
   --  and then store content inside.
   function Search_Empty_Mark (First, Last   : Handle_Index_Type;
                               Data          : in Ratp.Packet_Stream;
                               Seq_Nb        : Reliable_Udp.Pkt_Nb) return Boolean;

   procedure Save_Ack (Seq_Nb                :  in Reliable_Udp.Pkt_Nb;
                       Packet_Number         :  in Reliable_Udp.Pkt_Nb;
                       Data                  :  in Ratp.Packet_Stream);

   --  Move Data Received to good location (Nb_Missed Offset) if packets
   --  were dropped
   procedure Copy_To_Correct_Location
                            (I, Nb_Missed    : Interfaces.Unsigned_64;
                             Data            : Ratp.Packet_Stream;
                             Data_Addr       : System.Address);

   --  Write 16#DEAD_BEEF# at missed packets location.
   --  Enables Search_Empty_Mark to save ack in correct Cell
   procedure Mark_Empty_Cell (I              :  Interfaces.Unsigned_64;
                              Data_Addr      :  System.Address;
                              Last_Addr      :  System.Address;
                              Nb_Missed      :  Interfaces.Unsigned_64);

   --  [CTL] Gets a new Dest Buffer, and a new Src_Buffer if it's necessary.
   function New_Dest_Buffer (Dest_Buffer     : Buffers.Buffer_Produce_Access;
                             Size            : Interfaces.Unsigned_32;
                             Buffer_Size     : in out Interfaces.Unsigned_32;
                             Packet_Nb       : in out Interfaces.Unsigned_64;
                             Src_Index       : in out Interfaces.Unsigned_64;
                             Src_Handle      : in out Buffers.Buffer_Handle_Access;
                             Dest_Index      : in out Ada.Streams.Stream_Element_Offset;
                             Dest_Handle     : in out Buffers.Buffer_Handle_Access;
                             Src_Data_Stream : Ratp.Sequence_Type) return Boolean;

   --  [CTL] Src_Handle get a new Src_Buffer if it's necessary returns 1 otherwise 0
   function New_Src_Buffer (Src_Index        : in out Interfaces.Unsigned_64;
                            Src_Handle       : in out Buffers.Buffer_Handle_Access;
                            Src_Data_Stream  : Ratp.Sequence_Type) return Boolean;

   procedure New_Src_Buffer (Src_Index       : in out Interfaces.Unsigned_64;
                             Src_Handle      : in out Buffers.Buffer_Handle_Access;
                             Src_Data_Stream : Ratp.Sequence_Type);

   --  [CTL] Copies RATP Buffer's segment to CTL Dest Buffer.
   --  (Removes all the headers)
   procedure Copy_Packet_Data_To_Dest
                           (Buffer_Size      : Interfaces.Unsigned_32;
                            Src_Index        : in out Interfaces.Unsigned_64;
                            Src_Handle       : in out Buffers.Buffer_Handle_Access;
                            Dest_Handle      : Buffers.Buffer_Handle_Access;
                            Dest_Index       : in out Ada.Streams.Stream_Element_Offset;
                            Src_Data_Stream  : Ratp.Sequence_Type);

   --  Release Buffer and Reuse Handler only if Buffer State is "Full"
   task type Release_Full_Buf is
      entry Start;
   end Release_Full_Buf;

   --  Get the address of a New Buffer
   task type PMH_Buffer_Addr is
      entry Stop;
      entry New_Buffer_Addr (Buffer_Ptr : in out System.Address);
   end PMH_Buffer_Addr;

   --  Change Buffer State from "Near_Full" to "Full" only if it contains
   --  all Packets
   task type Check_Buf_Integrity is
      entry Start;
   end Check_Buf_Integrity;

   --  [CTL] Moves RATP buffers content to CTL destination buffer.
   task type Handle_Data_Task is
      entry Start (Buffer_Set : Buffers.Buffer_Produce_Access);
   end Handle_Data_Task;

end Ratp.Buffer_Handling;