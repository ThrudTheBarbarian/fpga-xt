--------------------------------------------------------------------------------
-- Copyright (C) 2013-2025 Efinix Inc. All rights reserved.              
--
-- This   document  contains  proprietary information  which   is        
-- protected by  copyright. All rights  are reserved.  This notice       
-- refers to original work by Efinix, Inc. which may be derivitive       
-- of other work distributed under license of the authors.  In the       
-- case of derivative work, nothing in this notice overrides the         
-- original author's license agreement.  Where applicable, the           
-- original license agreement is included in it's original               
-- unmodified form immediately below this header.                        
--                                                                       
-- WARRANTY DISCLAIMER.                                                  
--     THE  DESIGN, CODE, OR INFORMATION ARE PROVIDED “AS IS” AND        
--     EFINIX MAKES NO WARRANTIES, EXPRESS OR IMPLIED WITH               
--     RESPECT THERETO, AND EXPRESSLY DISCLAIMS ANY IMPLIED WARRANTIES,  
--     INCLUDING, WITHOUT LIMITATION, THE IMPLIED WARRANTIES OF          
--     MERCHANTABILITY, NON-INFRINGEMENT AND FITNESS FOR A PARTICULAR    
--     PURPOSE.  SOME STATES DO NOT ALLOW EXCLUSIONS OF AN IMPLIED       
--     WARRANTY, SO THIS DISCLAIMER MAY NOT APPLY TO LICENSEE.           
--                                                                       
-- LIMITATION OF LIABILITY.                                              
--     NOTWITHSTANDING ANYTHING TO THE CONTRARY, EXCEPT FOR BODILY       
--     INJURY, EFINIX SHALL NOT BE LIABLE WITH RESPECT TO ANY SUBJECT    
--     MATTER OF THIS AGREEMENT UNDER TORT, CONTRACT, STRICT LIABILITY   
--     OR ANY OTHER LEGAL OR EQUITABLE THEORY (I) FOR ANY INDIRECT,      
--     SPECIAL, INCIDENTAL, EXEMPLARY OR CONSEQUENTIAL DAMAGES OF ANY    
--     CHARACTER INCLUDING, WITHOUT LIMITATION, DAMAGES FOR LOSS OF      
--     GOODWILL, DATA OR PROFIT, WORK STOPPAGE, OR COMPUTER FAILURE OR   
--     MALFUNCTION, OR IN ANY EVENT (II) FOR ANY AMOUNT IN EXCESS, IN    
--     THE AGGREGATE, OF THE FEE PAID BY LICENSEE TO EFINIX HEREUNDER    
--     (OR, IF THE FEE HAS BEEN WAIVED, $100), EVEN IF EFINIX SHALL HAVE 
--     BEEN INFORMED OF THE POSSIBILITY OF SUCH DAMAGES.  SOME STATES DO 
--     NOT ALLOW THE EXCLUSION OR LIMITATION OF INCIDENTAL OR            
--     CONSEQUENTIAL DAMAGES, SO THIS LIMITATION AND EXCLUSION MAY NOT   
--     APPLY TO LICENSEE.                                                
--
--------------------------------------------------------------------------------
------------- Begin Cut here for COMPONENT Declaration ------
component hyperram is
port (
    ram_clk_cal : in std_logic;
    ram_clk : in std_logic;
    rst : in std_logic;
    hbc_cal_pass : out std_logic;
    hbc_ck_n_LO : out std_logic;
    hbc_ck_n_HI : out std_logic;
    hbc_ck_p_LO : out std_logic;
    hbc_ck_p_HI : out std_logic;
    hbc_cs_n : out std_logic;
    hbc_rst_n : out std_logic;
    hbc_cal_SHIFT_SEL : out std_logic_vector(4 downto 0);
    hbc_cal_SHIFT : out std_logic_vector(2 downto 0);
    hbc_cal_SHIFT_ENA : out std_logic;
    native_clk : in std_logic;
    native_ram_en : in std_logic;
    native_ram_address : in std_logic_vector(31 downto 0);
    native_ctrl_idle : out std_logic;
    native_rd_valid : out std_logic;
    native_wr_buf_ready : out std_logic;
    native_ram_burst_len : in std_logic_vector(10 downto 0);
    native_wr_en : in std_logic;
    native_ram_rdwr : in std_logic;
    hbc_dq_OE : out std_logic_vector(7 downto 0);
    hbc_dq_IN_LO : in std_logic_vector(7 downto 0);
    hbc_dq_IN_HI : in std_logic_vector(7 downto 0);
    hbc_dq_OUT_LO : out std_logic_vector(7 downto 0);
    hbc_dq_OUT_HI : out std_logic_vector(7 downto 0);
    hbc_rwds_OE : out std_logic_vector(0 to 0);
    hbc_rwds_IN_LO : in std_logic_vector(0 to 0);
    hbc_rwds_IN_HI : in std_logic_vector(0 to 0);
    hbc_rwds_OUT_LO : out std_logic_vector(0 to 0);
    hbc_rwds_OUT_HI : out std_logic_vector(0 to 0);
    native_wr_data : in std_logic_vector(63 downto 0);
    native_wr_datamask : in std_logic_vector(7 downto 0);
    native_rd_data : out std_logic_vector(63 downto 0);
    hbc_cal_debug_info : out std_logic_vector(26 downto 0);
    dyn_pll_phase_sel : in std_logic_vector(2 downto 0);
    dyn_pll_phase_en : in std_logic
);
end component hyperram;

---------------------- End COMPONENT Declaration ------------
------------- Begin Cut here for INSTANTIATION Template -----
u_hyperram : hyperram
port map (
    ram_clk_cal => ram_clk_cal,
    ram_clk => ram_clk,
    rst => rst,
    hbc_cal_pass => hbc_cal_pass,
    hbc_ck_n_LO => hbc_ck_n_LO,
    hbc_ck_n_HI => hbc_ck_n_HI,
    hbc_ck_p_LO => hbc_ck_p_LO,
    hbc_ck_p_HI => hbc_ck_p_HI,
    hbc_cs_n => hbc_cs_n,
    hbc_rst_n => hbc_rst_n,
    hbc_cal_SHIFT_SEL => hbc_cal_SHIFT_SEL,
    hbc_cal_SHIFT => hbc_cal_SHIFT,
    hbc_cal_SHIFT_ENA => hbc_cal_SHIFT_ENA,
    native_clk => native_clk,
    native_ram_en => native_ram_en,
    native_ram_address => native_ram_address,
    native_ctrl_idle => native_ctrl_idle,
    native_rd_valid => native_rd_valid,
    native_wr_buf_ready => native_wr_buf_ready,
    native_ram_burst_len => native_ram_burst_len,
    native_wr_en => native_wr_en,
    native_ram_rdwr => native_ram_rdwr,
    hbc_dq_OE => hbc_dq_OE,
    hbc_dq_IN_LO => hbc_dq_IN_LO,
    hbc_dq_IN_HI => hbc_dq_IN_HI,
    hbc_dq_OUT_LO => hbc_dq_OUT_LO,
    hbc_dq_OUT_HI => hbc_dq_OUT_HI,
    hbc_rwds_OE => hbc_rwds_OE,
    hbc_rwds_IN_LO => hbc_rwds_IN_LO,
    hbc_rwds_IN_HI => hbc_rwds_IN_HI,
    hbc_rwds_OUT_LO => hbc_rwds_OUT_LO,
    hbc_rwds_OUT_HI => hbc_rwds_OUT_HI,
    native_wr_data => native_wr_data,
    native_wr_datamask => native_wr_datamask,
    native_rd_data => native_rd_data,
    hbc_cal_debug_info => hbc_cal_debug_info,
    dyn_pll_phase_sel => dyn_pll_phase_sel,
    dyn_pll_phase_en => dyn_pll_phase_en
);

------------------------ End INSTANTIATION Template ---------
