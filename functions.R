gpu.pvclust.parallel <- function(data, method.hclust="average", method.dist="correlation", use.cor="pairwise.complete.obs", nboot=1000, r=seq(.5,1.4,by=.1), store=FALSE, weight=FALSE, iseed=NULL, quiet=FALSE, init.rand = NULL, ncores = 1)
{
  require(gputools)
  require(parallel)

  #source pvcluster-internal from wherever you cloned the repo 
  source("pvclust-internal.R",local = FALSE)

  #looks for environment variables NUM_CORES to set parallel, otherwise hard code some number here
  par.size <- as.numeric(Sys.getenv("NUM_CORES"))
  if(is.na(par.size)){par.size = ncores}
  cl <- parallel::makePSOCKcluster(names = par.size, outfile = "")
  on.exit(stopCluster(cl))


  if(!is.null(iseed) && (is.null(init.rand) || init.rand)){
    parallel::clusterSetRNGStream(cl = cl, iseed = iseed)
  }
  
  # data: (n,p) matrix, n-samples, p-variables
  n <- nrow(data); p <- ncol(data)
  
  # hclust for original data
  if(is.function(method.dist)) {
    # Use custom distance function
    distance <- method.dist(data)
  } else {
    distance <- dist.pvclust.gpu(data, method=method.dist, use.cor=use.cor)
  }
  
  data.hclust <- gputools::gpuHclust(distance, method = method.hclust)
  
  # ward -> ward.D
  # only if R >= 3.1.0
  if(method.hclust == "ward" && getRversion() >= '3.1.0') {
    method.hclust <- "ward.D"
  }
  
  # multiscale bootstrap
  size <- floor(n*r)
  rl <- length(size)
  
  if(rl == 1) {
    if(r != 1.0){
      warning("Relative sample size r is set to 1.0. AU p-values are not calculated\n")
    }
    r <- list(1.0)
  }
  else{
    r <- as.list(size/n)
  }
  
  ncl <- length(cl)
  nbl <- as.list(rep(nboot %/% ncl,times=ncl))
  
  if((rem <- nboot %% ncl) > 0)
    nbl[1:rem] <- lapply(nbl[1:rem], "+", 1)
  
  if(!quiet)
    cat("Multiscale bootstrap... \n")
  
  clusterExport(cl, "boot.hclust.gpu")
  clusterExport(cl, "dist.pvclust.gpu")
  
  mlist <- parallel::parLapply(cl, nbl, pvclust.node.gpu, r=r, data=data, object.hclust=data.hclust, method.dist=method.dist,
                               use.cor=use.cor, method.hclust=method.hclust,
                               store=store, weight=weight, quiet=quiet)
  if(!quiet)
    cat("Done.\n")
  
  mboot <- mlist[[1]]
  
  for(i in 2:ncl) {
    for(j in 1:rl) {
      mboot[[j]]$edges.cnt <- mboot[[j]]$edges.cnt + mlist[[i]][[j]]$edges.cnt
      mboot[[j]]$nboot <- mboot[[j]]$nboot + mlist[[i]][[j]]$nboot
      mboot[[j]]$store <- c(mboot[[j]]$store, mlist[[i]][[j]]$store)
    }
  }
  
  result <- pvclust.merge(data=data, object.hclust=data.hclust, mboot=mboot)

  return(result)
}

pvclust.node.gpu <- function(x, r, ...)
{
  #selectedGpu <- Sys.getenv("CUDA_VISIBLE_DEVICES")
  #if(length(selectedGpu) > 1){
  #  selectedGpu <- sample(0:1, 1)
  #} else {
  #  selectedGpu <- 0
  #}
  #gputools::chooseGpu(deviceId = selectedGpu)
  mboot.node <- lapply(r, FUN = boot.hclust.gpu , nboot=x, ...)
  return(mboot.node)
}

boot.hclust.gpu <- function(r, data, object.hclust, method.dist, use.cor, method.hclust, nboot, store, weight=FALSE, quiet=FALSE)
{ 
  source("pvclust-internal.R")
  
  n <- nrow(data)
  size  <- round(n*r, digits=0)
  if(size == 0)
    stop("invalid scale parameter(r)")
  r <- size/n
  
  pattern   <- hc2split(object.hclust)$pattern
  edges.cnt <- table(factor(pattern)) - table(factor(pattern))
  st <- list()
  
  # bootstrap start
  rp <- as.character(round(r,digits=2)); if(r == 1) rp <- paste(rp,".0",sep="")
  if(!quiet)
    cat(paste("Bootstrap (r = ", rp, ")... ", sep=""))
  w0 <- rep(1,n) # equal weight
  na.flag <- 0
  
  for(i in 1:nboot){
    if(weight && r>10) {  ## <- this part should be improved
      warning("not gpu optimized")
      w1 <- as.vector(rmultinom(1,size,w0)) # resampled weight
      suppressWarnings(distance <- distw.pvclust(data,w1,method=method.dist,use.cor=use.cor))
    } else {
      smpl <- sample(1:n, size, replace=TRUE)
      if(is.function(method.dist)) {
        warning("calling own method, probably not gpu optimized")
        suppressWarnings(distance  <- method.dist(data[smpl,]))
      } else {
        suppressWarnings(distance  <- dist.pvclust.gpu(data[smpl,],method=method.dist,use.cor=use.cor))
      }
    }
    if(all(is.finite(distance))) { # check if distance is valid
      x.hclust  <- gputools::gpuHclust(distance,method=method.hclust)
      pattern.i <- hc2split(x.hclust)$pattern # split
      edges.cnt <- edges.cnt + table(factor(pattern.i,  levels=pattern))
    } else {
      x.hclust <- NULL
      na.flag <- 1
    }
    
    if(store)
      st[[i]] <- x.hclust
  }
  if(!quiet)
    cat("Done.\n")
  # bootstrap done
  
  if(na.flag == 1)
    warning(paste("inappropriate distance matrices are omitted in computation: r = ", r), call.=FALSE)
  
  boot <- list(edges.cnt=edges.cnt, method.dist=method.dist, use.cor=use.cor,
               method.hclust=method.hclust, nboot=nboot, size=size, r=r, store=st)
  class(boot) <- "boot.hclust"
  
  return(boot)
}

dist.pvclust.gpu <- function(x, method="euclidean", use.cor="pairwise.complete.obs")
{
  require(gputools)
  
  cor_matrix <- gputools::gpuCor(x, method="pearson", use=use.cor)
  cor_matrix <- cor_matrix$coefficients
  
  colnames(cor_matrix) <- rownames(cor_matrix) <- colnames(x)
  
  if(!is.na(pmatch(method,"correlation"))){
    res <- as.dist(1 - cor_matrix)
    attr(res,"method") <- "correlation"
    return(res)
  }
  else if(!is.na(pmatch(method,"abscor"))){
    res <- as.dist(1 - abs(cor_matrix))
    attr(res,"method") <- "abscor"
    return(res)
  }
  else if(!is.na(pmatch(method,"uncentered"))){
    if(sum(is.na(x)) > 0){
      x <- na.omit(x)
      warning("Rows including NAs were omitted")
    }
    x  <- as.matrix(x)
    P  <- gputools::gpuCrossprod(x)
    rownames(P) <- colnames(P) <- colnames(x)
    qq <- matrix(diag(P),ncol=ncol(P))
    Q  <- sqrt(gputools::gpuCrossprod(qq))
    res <- as.dist(1 - P/Q)
    attr(res,"method") <- "uncentered"
    return(res)
  }
  else
    dist_m <- gputools::gpuDist(t(x),method)
}
