# AS-IS
## The scenario is that the PE/PIE/FABModule engineers must be Knowlwdgeable, which means they must have the Domain knowledge, and need many SOPs to follow the  step by step analysis procedure to do the Engineering Data Analysis. It is current status of the old EDA system. And it’s correlation analysis only for some dimensions lacking holistic or complex combination
analysis.


 
# TO-BE
## The scenario is that PE/PIE/FABModule Engineers just provide the Good and Bad Wafer list, the new generation EDA system can automatically to fetch the related data such as MES data, Process data, FDC data, SPC data, CP or WAT data, Metrology data, and even the Material COA data.The system will implement the Machine Learning and Deep Learning even the AI(LLM) Model to automatically do the data insight analysis to identify the potential factor that will impact the wafer performance for Root Cause Analysis.




| Dimension             | AS-IS: VEDA1/2 (Current)                                                                 | TO-BE: Next-Gen EDA (Proposed)                                                                       | Strategic Impact                                   |  
|-----------------------|-------------------------------------------------------------------------------------------|-------------------------------------------------------------------------------------------------------|----------------------------------------------------|  
| **Analysis Approach** | - Reactive: Analyze after issues occur<br>- Engineer selects 1 of 26 functions<br>- Correlation-based ranking | - Proactive: Predict 24–48 hrs ahead<br>- AI auto-selects optimal analysis<br>- Causal root cause identification | - Prevent vs firefight<br>- Shift from reactive to predictive |  
| **Root Cause Accuracy** | - Engineer Know-How is must<br>- 60% finding rate<br>- 20% false positives              | - AI enabled and self-guiding<br>- 90% finding rate<br>- 5% false positives                          | - 50% accuracy improvement<br>- 75% fewer false alarms |  
| **Analysis Speed**    | - 2 hours to 2 days<br>- Manual data collection<br>- Sequential analysis                 | - 10 minutes to 2 hours average<br>- Automated data fusion<br>- Parallel data processing / SAS In-Memory | - Analysis time reduction<br>- Real-time decision making |  
| **Data Integration**  | - 10 data sources<br>- Batch ETL (daily/weekly)<br>- Siloed databases                    | - All fab data sources<br>- ETL + Real-time streaming (< 1 sec)<br>- Unified data warehouse          | - 360° visibility<br>- Holistic manufacturing view |  
| **Pattern Recognition** | - Manual wafer map inspection<br>- Engineer expertise dependent<br>- Inconsistent classification | - AI wafer map + GAN (95% accuracy)<br>- Automated defect detection<br>- Consistent, 24/7 operation | - Remove human bottleneck<br>- Scale expert knowledge |  
| **Predictive Capability** | - None – reactive only<br>- Historical analysis<br>- Post-mortem reviews             | - Yield forecasting (85% accuracy)<br>- Equipment failure prediction (7–14 days)<br>- Process drift early warning | - Proactive intervention<br>- Prevent yield loss   |  
| **User Experience**   | - Desktop app, single location<br>- Steep learning curve<br>- 26 separate functions      | - Web + API<br>- Natural language interface (LLM)<br>- Unified intelligent assistant                 | - Anytime access<br>- Democratize insights         |  
| **Core Technology**   | - Statistical correlation<br>- Manual function selection                                 | - ML/DL + statistical correlation<br>- Autonomous AI agents                                          | - Future-proof architecture<br>- AI enabling       |  


# EDA Release Schedule  
  
- Consult TSMC iEDA Sponsor, item 14 – Automatic Map Recognition is challenge and VSMC will POC first.  
  
| #  | Phase | AP                                                      | Description                                                                                                                                                                                                 | UAT (MM/DD/YYYY) | Release (Prod.)                         |  
|----|:-----:|---------------------------------------------------------|-------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------|------------------|-----------------------------------------|  
| 0  | 1     | Standard analysis functions for Inline/Offline, WAT, CP/SP data | Support Inline/Offline, WAT, CP/SP data. Support standard charts, maps, correlation, Annova, tool commonality.                                                                                             | 09/30/2025       | 10/31/2025                              |  
| 1  | 1     | CP vs FDC U-Chart                                      | Reference 200mm CP vs RTM AP.                                                                                                                                                                              | 01/01/2026       | 03/01/2026                              |  
| 2  | 1     | WAT vs FDC U-Chart                                     | Reference 200mm WAT vs RTM AP.                                                                                                                                                                             | 11/22/2025       | 03/01/2026                              |  
| 3  | 1     | CP/WAT vs Q-Time (wafer level)                         | New: Current eqp track out to next eqp track in.                                                                                                                                                           | 01/01/2026       | 03/01/2026                              |  
| 4  | 1     | CP/WAT vs Multi-Stage                                  | Reference 200mm AP but enhance to wafer/chamber.                                                                                                                                                           | 01/01/2026       | 03/01/2026                              |  
| 5  | 1     | Customize merge rule                                   | Reference 200mm merge rule AP.                                                                                                                                                                             | 11/20/2025       | 12/31/2025                              |  
| 6  | 1     | CP vs DCOP/MQC/OVL map stack                           | Modify 200mm CP Map AP, stack DCOP / MQC / OVL map on CP map.                                                                                                                                              | 02/28/2026       | 03/01/2026                              |  
| 7  | 1     | Customized Zone correlation                            | Modify 200mm AP, use customize zone fail rate as Y to do correlation.                                                                                                                                      | 12/07/2025       | 03/01/2026                              |  
| 8  | 1     | Datalog (SP) defense system                            | Modify 200mm SP early detection AP.                                                                                                                                                                        | 03/01/2026       | 03/01/2026                              |  
| 9  | 1     | Batch run & all in one yield/bin/map                   | Modify 200mm CP dashboard AP.                                                                                                                                                                              | 02/01/2026       | 03/01/2026                              |  
| 10 | 1     | Auto Reporting                                         | Add auto-generated PowerPoint reports with customizable layout and sending email.                                                                                                                          | 02/01/2026       | 03/01/2026                              |  
| 11 | 1     | 4 in 1 charts                                          | Add tsmc commonly used standard 4 in 1 charts report format.                                                                                                                                               | 02/01/2026       | 03/01/2026                              |  
| 12 | 2     | Automatic Good/Bad Wafer Grouping                      | Enable automatic classification of wafers into good and bad groups to streamline root cause analysis and yield monitoring.                                                                                 | —                | —                                       |  
| 13 | 2     | Automatic Correlation Analysis for Possible Root Causes | Automatically analyze process and equipment data to identify the most likely root causes of wafer anomalies. Propose the buy or build strategy and budget for extra 300mm key features by 12/31/2025.     | —                | —                                       |  
| 14 | 3     | Automatic Map Recognition for Correlation / Possible Root Causes | Leverage wafer map pattern recognition to detect spatially correlated defects or yield loss and suggest related process causes.                                                                            | —                | Wish: 12/31/2026                        |  
| 15 | 2     | Automatic Reporting for Automatic Correlation Analysis | Generate automated, professional-quality reports to summarize analysis findings for engineers or management.                                                                                               | —                | —                                       |  


# VEDA Advanced Solution Evaluation Report  
  
## Vendors and In-House Comparisons  
  
- Synopsys, Semitronix, and VIS VEDA2 scoring \<50% maturity; VEDA2 29% can be VSMC foundation.  
- For cost, Synopsys did not provide; Semitronix \$1,430K (5 yrs MA); VSMC initial investment for SAS Viya is \$1,801K.  
- Project Model: VSMC team designs core functions, SAS team is the consultant, 3rd outsourcing party dedicated on web application.  
  
## Evaluation Summary  
  
| Evaluation Criteria                 | Synopsys                | Semitronix                                    | In-House Development                          |  
|------------------------------------|-------------------------|-----------------------------------------------|-----------------------------------------------|  
| **Solution Maturity (vs. TSMC iGene)** | 36%                     | 44%                                           | 29% (VEDA2 baseline)                          |  
| **Extra SW License + MA**          | \$350K (License only)   | \$600K + 18% MA (540K – 5 yrs) License + MA   | \$0 (SAS Viya) License + MA                   |  
| **Customization Cost**             | TBD                     | \$140K                                        | (\$800K) SAS Consultant + Outsourcing         |  
| **Hardware Cost**                  | TBD                     | \$150K                                        | \$0 (SAS Server)                              |  
| **Total**                          | TBD                     | \$1,430K (890K + 540K)                        | (\$800K)                                      |  

# SAS Consultant and Outsourcing Vendor Survey  
  
- Surveyed 4 vendors considering onsite support (PIP concern), SAS development capability.  
- Cost efficiency to select SAS Consultant and Outsourcing; need procurement to negotiate a good price.  
- Co-work model aiming at knowledge transfer; vendors are isolated by independent scope.  
  
## Vendor Comparison  
  
| Evaluation Criteria      | SAS Institute (Singapore) | SAS Partner (Nupeak / India) | AlphaXTech (Singapore) | Qynix (Malaysia) |  
|--------------------------|---------------------------|------------------------------|------------------------|------------------|  
| **Man-Month Rate**       | US\$ 20K                  | US\$ 5K                      | US\$ 7K                | US\$ 4K          |  
| **Onsite/Remote (PIP)**  | Onsite                    | Remote                       | Onsite                 | Remote           |  
| **SAS Viya Capability**  | Strong                    | Middle                       | Low                    | Low              |  
| **Working Model**        | —                         | 1. Pair programming with vendors<br>2. Consult for technical support<br>3. On-the-job training | —                      | —                |  
| **Implement Scope**      | EDA Analysis Core function | —                            | Web GUI APP Development | —               |  
  
## Investment, Schedule, Benefit  
  
- **Investment CAPEX:** US\$ 800K (20 Man-Month * 20K/Month + 21 Man-Month * 7K/Month) + 30% buffer    
- **Schedule:** Feb-2026 to Feb-2027    
- **Benefit:** Establish a fast and accurate Engineering Data Analysis system to reduce analysis cycle time and meet customers’ needs for yield improvement.

  # VSMC, SAS, and Outsourcing Resource Arrangement  
  
## Resource Table  
  
| #  | Phase | AP                                              | Man-Month | SAS                                             | Outsourcing                                      | VSMC                            |  
|----|:-----:|--------------------------------------------------|-----------|-------------------------------------------------|--------------------------------------------------|---------------------------------|  
| 1  | 1     | CP vs FDC U-Chart                               | 5         | 0                                               | 0                                                | 5 VSMC – Yanrui Wei             |  
| 2  | 1     | WAT vs FDC U-Chart                              | 5         | 0                                               | 0                                                | 5 VSMC – Hui Qi Lee             |  
| 3  | 1     | CP/WAT vs Q-Time (wafer level)                  | 1         | 0                                               | 0                                                | 1 VSMC – Chris                  |  
| 4  | 1     | CP/WAT vs Multi-Stage                           | 2         | 0                                               | 0                                                | 2 VSMC – Yong Chang             |  
| 12 | 2     | Automatic Good/Bad Wafer Grouping               | 13        | 5                                               | 6                                                | 2                               |  
| 13 | 2     | Automatic Correlation Analysis for Possible Root Causes | 23 (ML/DL model, traceable process data, dynamic GUI) | 12 (Data manipulation, algorithm)               | 10 (Different charting, data griding, interactive) | 2                               |  
| 14 | 3     | AI Wafer Map for Correlation for Root Cause investigation (POC first) | 3         | 0                                               | 0                                                | 3                               |  
| 15 | 2     | Automatic Reporting for Automatic Correlation Analysis | 10        | 3                                               | 5                                                | 2                               |  
|    |       | **FAB Urgent Requirement**                      | 13        | 8                                               | 4                                                | 0                               |  
|    |       | **Total**                                       | **75**    | **28**                                          | **25**                                           | **22**                          |  
  
## Workload Estimation and Outcome  
  
- **Workload estimation for 53 functions and 30 major (total 70) SAS migration to CAS**  
  - Estimated using 200mm development experience, vendor RFP data, and TSMC benchmarks.  
  - Over 80 functions require resources; with only 4 DAP engineers, schedule targets cannot be met, so SAS support and outsourcing are needed to accelerate releases for FAB yield ramp.  
- **After 12 months**, DAP team becomes self-sufficient, able to troubleshoot, optimize, and build new analytics independently from vendors.

# Project Milestones  
  
1. Kick-Off project meeting – 12/2/2026    
2. URD review and confirm – 13/3/2026    
3. PR/PO for Vendors – 30/3/2026    
4. System Architecture Design – 17/4/2026    
5. Production Release – 28/2/2027    
  
## Release Plan  
  
| #  | Phase | AP                                              | Description                                                                                                       | UAT (MM/DD/YYYY) | Release (Prod.) |  
|----|:-----:|--------------------------------------------------|-------------------------------------------------------------------------------------------------------------------|------------------|-----------------|  
| 1  | 1     | CP vs FDC U-Chart                               | Reference 200mm CP vs RTM AP                                                                                      | 08/24/2026       | 09/01/2026      |  
| 2  | 1     | WAT vs FDC U-Chart                              | Reference 200mm WAT vs RTM AP                                                                                     | 10/24/2026       | 11/01/2026      |  
| 3  | 1     | CP/WAT vs Q-Time (wafer level)                  | New: Current eqp track out to next eqp track in                                                                   | 08/24/2026       | 09/01/2026      |  
| 4  | 1     | CP/WAT vs Multi-Stage                           | Reference 200mm AP but enhance to wafer/chamber level                                                             | 08/24/2026       | 09/01/2026      |  
| 12 | 2     | Automatic Good/Bad Wafer Grouping               | Enable automatic classification of wafers into good and bad groups to streamline root cause analysis and yield monitoring | 07/31/2026       | 08/31/2026      |  
| 13 | 2     | Automatic Correlation Analysis for Possible Root Causes | Automatically analyze process and equipment data to identify the most likely root causes of wafer anomalies      | 09/30/2026       | 10/31/2026      |  
| 14 | 3     | Automatic Map Recognition for Correlation / Possible Root Causes | Leverage wafer map pattern recognition to detect spatially correlated defects or yield loss and suggest related process causes | 09/30/2027       | 10/30/2027      |  
| 15 | 2     | Automatic Reporting for Automatic Correlation Analysis | Generate automated, professional-quality reports to summarize analysis findings for engineers and management     | 12/30/2026       | 01/30/2027      |  
