library(pomp)

library(tidyverse)
polio_data <- read_csv("polio_wisconsin.csv",comment="#")
head(polio_data,5)

polio_data %>%
  gather(variable,value,-time) %>%
  ggplot(aes(x=time,y=value))+
  geom_line()+
  facet_wrap(~variable,ncol=1,scales='free_y',strip.position = "left")+
  theme(
    strip.background=element_rect(fill=NA,color=NA),
    strip.placement="outside"
  )+
  labs(x="",y="")

polio_statenames <- c("SB1","SB2","SB3","SB4","SB5","SB6",
                      "IB","SO","IO")
polio_obsnames <- "cases"
polio_t0 <- 1932+4/12

library(pomp)
polio_K <- 6
polio_covar <- covariate_table(
  t=polio_data$time,
  B=polio_data$births,
  P=predict(smooth.spline(x=1931:1954,
    y=polio_data$pop[seq(12,24*12,by=12)]))$y,
  periodic.bspline.basis(t,nbasis=polio_K,
    degree=3,period=1,names="xi%d"),
  times="t"
)

polio_rp_names <- c("b1","b2","b3","b4","b5","b6",
                    "psi","rho","tau","sigma_dem","sigma_env")

polio_ivp_names <- c("SO_0","IO_0")
polio_paramnames <- c(polio_rp_names,polio_ivp_names)

polio_fp_names <- c("delta","K",
         "SB1_0","SB2_0","SB3_0","SB4_0","SB5_0","SB6_0")
polio_paramnames <- c(polio_rp_names,
                      polio_ivp_names,polio_fp_names)
covar_index_t0 <- which(abs(polio_covar@times-polio_t0)<0.01)
polio_initial_births <- polio_covar@table["B",covar_index_t0-0:5]
names(polio_initial_births) <- c("SB1_0","SB2_0",
                                 "SB3_0","SB4_0","SB5_0","SB6_0") 
polio_fixed_params <- c(delta=1/60,K=polio_K,
                        polio_initial_births)

polio_params_guess <- c(b1=3,b2=0,b3=1.5,b4=6,b5=5,b6=3,
                        psi=0.002,rho=0.01,tau=0.001,
			  sigma_dem=0.04,sigma_env=0.5,
                        SO_0=0.12,IO_0=0.001,polio_fixed_params)

polio_rprocess <- Csnippet("
double beta = exp(dot_product( (int) K, &xi1, &b1));
double lambda = (beta * (IO+IB) / P + psi);
double var_epsilon = pow(sigma_dem,2)/ lambda +  
  pow(sigma_env,2);
lambda *= (var_epsilon < 1.0e-6) ? 1 : 
  rgamma(1/var_epsilon,var_epsilon);
double p = exp(- (delta+lambda)/12);
double q = (1-p)*lambda/(delta+lambda);
SB1 = B;
SB2= SB1*p;
SB3=SB2*p;
SB4=SB3*p;
SB5=SB4*p;
SB6=SB5*p;
SO= (SB6+SO)*p;
IB=(SB1+SB2+SB3+SB4+SB5+SB6)*q;
IO=SO*q;
")

polio_dmeasure <- Csnippet("
double tol = 1.0e-25;
double mean_cases = rho*IO;
double sd_cases = sqrt(pow(tau*IO,2) + mean_cases);
if(cases > 0.0){
  lik = pnorm(cases+0.5,mean_cases,sd_cases,1,0)
    - pnorm(cases-0.5,mean_cases,sd_cases,1,0) + tol; 
} else{
  lik = pnorm(cases+0.5,mean_cases,sd_cases,1,0) + tol;
}
if (give_log) lik = log(lik);
")
polio_rmeasure <- Csnippet("
cases = rnorm(rho*IO, sqrt( pow(tau*IO,2) + rho*IO ) );
if (cases > 0.0) {
  cases = nearbyint(cases);
} else {
  cases = 0.0;
}
")

polio_rinit <- Csnippet("
SB1 = SB1_0;
SB2 = SB2_0;
SB3 = SB3_0;
SB4 = SB4_0;
SB5 = SB5_0;
SB6 = SB6_0;
IB = 0;
IO = IO_0 * P;
SO = SO_0 * P;
")

polio_partrans <- parameter_trans(
  log=c("psi","rho","tau","sigma_dem","sigma_env"),
  logit=c("SO_0","IO_0")
)

polio <- pomp(
  data=subset(polio_data, 
  (time > polio_t0 + 0.01) & (time < 1953+1/12+0.01),
  select=c("cases","time")),
  times="time",
  t0=polio_t0,
  params=polio_params_guess,
  rprocess = euler(step.fun = polio_rprocess, delta.t=1/12),
  rmeasure= polio_rmeasure,
  dmeasure = polio_dmeasure,
  covar=polio_covar,
  obsnames = polio_obsnames,
  statenames = polio_statenames,
  paramnames = polio_paramnames,
  rinit=polio_rinit,
  partrans=polio_partrans
)

run_level <- 3
polio_Np <-          switch(run_level,100, 1e3, 5e3)
polio_Nmif <-        switch(run_level, 10, 100, 200)
polio_Nreps_eval <-  switch(run_level,  2,  10,  20)
polio_Nreps_local <- switch(run_level, 10,  20,  40)
polio_Nreps_global <-switch(run_level, 10,  20, 100)
polio_Nsim <-        switch(run_level, 50, 100, 500) 

library(doParallel)
registerDoParallel()
library(doRNG)
registerDoRNG(3899882)

stew(file="results/pf1.rda",{
  t1 <- system.time(
    pf1 <- foreach(i=1:20,.packages='pomp') %dopar%
      pfilter(
        polio,Np=polio_Np)
  )
})
L1 <- logmeanexp(sapply(pf1,logLik),se=TRUE)

stew(file="results/persistence.rda",{
  t_sim <- system.time(
    sim <- foreach(i=1:polio_Nsim,.packages='pomp') %dopar%
      simulate(polio)
  )
})

no_cases_data <- sum(obs(polio)==0)
no_cases_sim <- sum(sapply(sim,obs)==0)/length(sim)
fadeout1_sim <- sum(sapply(sim,function(po)
  states(po)["IB",]+states(po)["IO",]<1))/length(sim)
fadeout100_sim <- sum(sapply(sim,function(po)
  states(po)["IB",]+states(po)["IO",]<100))/length(sim)
imports_sim <- coef(polio)["psi"]*mean(sapply(sim,function(po)
  mean(states(po)["SO",]+states(po)["SB1",]
       +states(po)["SB2",]+states(po)["SB3",]+states(po)["SB4",]
       +states(po)["SB5",]+states(po)["SB6",])))/12

mle_simulation <- simulate(polio,seed=127)
plot(mle_simulation)

polio_rw.sd_rp <- 0.02
polio_rw.sd_ivp <- 0.2
polio_cooling.fraction.50 <- 0.5
polio_rw.sd <- rw.sd(
  b1=polio_rw.sd_rp,b2=polio_rw.sd_rp,b3=polio_rw.sd_rp,
  b4=polio_rw.sd_rp,b5=polio_rw.sd_rp,b6=polio_rw.sd_rp,
  psi=polio_rw.sd_rp, rho=polio_rw.sd_rp,
  tau=polio_rw.sd_rp, sigma_dem=polio_rw.sd_rp,
  sigma_env=polio_rw.sd_rp,
  IO_0=ivp(polio_rw.sd_ivp), SO_0=ivp(polio_rw.sd_ivp)
)

stew(file="results/mif.rda",{
  t2 <- system.time({
    m2 <- foreach(i=1:polio_Nreps_local,
                  .packages='pomp', .combine=c) %dopar%
      mif2(polio,
           Np=polio_Np,
           Nmif=polio_Nmif,
           cooling.fraction.50=polio_cooling.fraction.50,
           rw.sd=polio_rw.sd)	
    lik_m2 <- foreach(i=1:polio_Nreps_local,
                      .packages='pomp', .combine=rbind) %dopar%
      logmeanexp(
        replicate(polio_Nreps_eval,logLik(
           pfilter(polio,params=coef(m2[[i]]),Np=polio_Np))),
        se=TRUE)
  })
})

r2 <- data.frame(logLik=lik_m2[,1],logLik_se=lik_m2[,2],
                 t(sapply(m2,coef)))
polio_results <- read.table("polio_params_in.csv",
                            row.names=NULL,header=T)
write.table(rbind(polio_results,r2),
            file="polio_params_out.csv",row.names=FALSE)
summary(r2$logLik,digits=5)

pairs(~logLik+psi+rho+tau+sigma_dem+sigma_env,
      data=subset(r2,logLik>max(logLik)-20))

polio_box <- rbind(
  b1=c(-2,8), b2=c(-2,8),
  b3=c(-2,8), b4=c(-2,8),
  b5=c(-2,8), b6=c(-2,8),
  psi=c(0,0.1), rho=c(0,0.1), tau=c(0,0.1),
  sigma_dem=c(0,0.5), sigma_env=c(0,1),
  SO_0=c(0,1), IO_0=c(0,0.01)
)

stew(file="results/box_eval.rda",{
  time_start_box_eval <- Sys.time()
  m3 <- foreach(i=1:polio_Nreps_global,.packages='pomp',
    .combine=c) %dopar% mif2(m2[[1]],
      params=c(apply(polio_box,1,function(x)runif(1,x[1],x[2])),
      polio_fixed_params)
                                         )
  lik_m3 <- foreach(i=1:polio_Nreps_global,.packages='pomp',
    .combine=rbind) %dopar% logmeanexp(
      replicate(polio_Nreps_eval,
        logLik(pfilter(polio,
          params=coef(m3[[i]]),Np=polio_Np))), 
      se=TRUE)
  time_end_box_eval <- Sys.time()
})

r3 <- data.frame(logLik=lik_m3[,1],logLik_se=lik_m3[,2],
                 t(sapply(m3,coef)))
if(run_level>1) write.table(r3,file="polio_params_out.csv",
  append=TRUE,col.names=FALSE,row.names=FALSE)
summary(r3$logLik,digits=5)

pairs(~logLik+psi+rho+tau+sigma_dem+sigma_env,
      data=subset(r3,logLik>max(logLik)-20))

nb_lik <- function(theta) - sum(dnbinom(as.vector(obs(polio)),
                  size=exp(theta[1]),prob=exp(theta[2]),log=TRUE))
nb_mle <- optim(c(0,-5),nb_lik)
-nb_mle$value

log_y <- log(as.vector(obs(polio))+1)
arma_fit <- arima(log_y,order=c(2,0,2),
                  seasonal=list(order=c(1,0,1),period=12))
arma_fit$loglik-sum(log_y)

polio_params <- read.table("polio_params_out.csv",row.names=NULL,
                           header=TRUE)
pairs(~logLik+psi+rho+tau+sigma_dem+sigma_env,
      data=subset(polio_params,logLik>max(logLik)-20))

## plot(logLik~rho,data=subset(r3,logLik>max(r3$logLik)-10),log="x")

par(mai=c(0.8,0.8,0.1,0.1))
plot(logLik~rho,data=subset(r3,logLik>max(r3$logLik)-10),log="x")

library(tidyverse)
polio_params %>% 
  filter(logLik>max(logLik)-20) %>%
  select(-logLik,-logLik_se,-rho) %>% 
  gather(variable,value) %>%  
  group_by(variable) %>%
  summarize(min=min(value),max=max(value)) %>%
  ungroup() %>%
  column_to_rownames(var="variable") %>%
  t() -> box

polio_profile_pts <-  switch(run_level,  3,  5,  30)
polio_profile_Nreps <- switch(run_level, 2,  3,  10)

profileDesign(
  rho=seq(0.01,0.025,length=polio_profile_pts),
  lower=box["min",],upper=box["max",],
  nprof=polio_profile_Nreps
) -> starts

  profile_rw.sd <- polio_rw.sd <- rw.sd(
    rho=0,
    b1=polio_rw.sd_rp,b2=polio_rw.sd_rp,b3=polio_rw.sd_rp,
    b4=polio_rw.sd_rp,b5=polio_rw.sd_rp,b6=polio_rw.sd_rp,
    psi=polio_rw.sd_rp,
    tau=polio_rw.sd_rp, sigma_dem=polio_rw.sd_rp,
    sigma_env=polio_rw.sd_rp,
    IO_0=ivp(polio_rw.sd_ivp), SO_0=ivp(polio_rw.sd_ivp)
  )

bake(file="results/profile_rho.rds",{  
  foreach(start=iter(starts,"row"),.combine=rbind) %dopar% {
    library(pomp)
    polio %>% mif2(params=unlist(start),
                   Np=polio_Np,
                   Nmif=ceiling(polio_Nmif/2),
                   cooling.fraction.50=0.5,
                   rw.sd=profile_rw.sd
                   ) %>% mif2(
                           Np=polio_Np,
                           Nmif=ceiling(polio_Nmif/2),
                           cooling.fraction.50=0.1
                         ) -> mf
    replicate(polio_Nreps_eval,
              mf %>% pfilter(Np=polio_Np) %>% logLik()
              ) %>% logmeanexp(se=TRUE) -> ll    
    data.frame(as.list(coef(mf)),logLik=ll[1],logLik.se=ll[2])
  }
}) -> m4

pairs(~logLik+psi+rho+tau+sigma_dem+sigma_env,data=subset(m4,logLik>max(logLik)-10))

m4 %>%
  bind_rows(polio_params) %>%
  arrange(-logLik) %>%
  write_csv(path="polio_params_out.csv")

## plot(m3[r3$logLik>max(r3$logLik)-10])

plot(m3[r3$logLik>max(r3$logLik)-10])

loglik_convergence <- do.call(cbind,
  traces(m3[r3$logLik>max(r3$logLik)-10],"loglik"))
matplot(loglik_convergence,type="l",lty=1,
        ylim=max(loglik_convergence,na.rm=T)+c(-10,0))
